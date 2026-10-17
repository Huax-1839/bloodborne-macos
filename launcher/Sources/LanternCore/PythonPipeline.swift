// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The pipeline as the repository's Python scripts (D4, v1): run with the bundle's own Python
/// (or a dev build's python3) as `python -E -s -B script.py ...`. Not -I: it would drop the
/// script's folder from sys.path, and the scripts import each other. -B: no __pycache__ in the
/// signed bundle.
public struct PythonPipeline: Pipeline {
    public let runtime: Runtime

    public init(runtime: Runtime) { self.runtime = runtime }

    public func quickCheck(game: URL) async throws -> GameCheck {
        let result = try await python(["game_check.py", "--quick", "--json", game.path], environment: [:])
        // Exit 1 is a problem found; the JSON says which.
        guard result.status == 0 || result.status == 1,
              let line = result.stdout.split(separator: "\n").last,
              let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw PipelineError("game_check.py failed (status \(result.status)): \(result.stderr.suffix(2000))")
        }
        let problem = (object["problem"] as? String).map { GameProblem(rawValue: $0) ?? .unreadable }
        return GameCheck(problem: problem, title: object["title"] as? String ?? "?",
                         version: object["version"] as? String ?? "?", imageSHA256: object["image_sha256"] as? String)
    }

    public func thoroughCheck(game: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String] {
        var broken: [String]?
        let result = try await python(["game_check.py", "--json", game.path], environment: [:]) { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            if let checked = object["checked"] as? Int, let total = object["total"] as? Int { progress(checked, total) }
            if let list = object["broken"] as? [String] { broken = list }
        }
        guard result.status == 0 || result.status == 1, let broken else {
            throw PipelineError("game_check.py failed (status \(result.status)): \(result.stderr.suffix(2000))")
        }
        return broken
    }

    public func scaledSizes(settings: URL) async throws -> ScaledSizes? {
        let result = try await python(["patches.py", "--print-scaled", "--settings", settings.path], environment: [:])
        guard result.status == 0 else { return nil } // run.sh: `|| true`
        let words = result.stdout.split(whereSeparator: \.isWhitespace)
        return words.count >= 2 ? ScaledSizes(render: String(words[0]), output: String(words[1])) : nil
    }

    public func buildModOverlay(game: URL, out: URL, modsDir: URL, config: URL) async throws -> URL {
        let result = try await python(["mods.py", game.path, "--out", out.path, "--mods-dir", modsDir.path,
                                       "--config", config.path, "--enabled", "1"], environment: [:])
        guard result.status == 0, let line = result.stdout.split(separator: "\n").last else {
            throw PipelineError(result.stderr.split(separator: "\n").last.map(String.init) ?? "mods.py failed (status \(result.status))")
        }
        return URL(fileURLWithPath: String(line), isDirectory: true)
    }

    public func run(_ step: LaunchSpec.Step, environment: [String: String], log: FileHandle?) async throws {
        let result = try await python([step.script] + step.arguments, environment: environment, log: log)
        guard result.status == 0 else {
            throw PipelineError("\(step.script) failed (status \(result.status)): \(result.stderr.suffix(4000))")
        }
    }

    /// Runs a script; stdout lines go to `onLine` as they come.
    func python(_ arguments: [String], environment: [String: String], log: FileHandle? = nil,
                onLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        var args = ["-E", "-s", "-B", runtime.scripts.appendingPathComponent(arguments[0]).path]
        args += arguments.dropFirst()
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { $1 }
        let result = try await ProcessRunner.run(runtime.python, arguments: args, environment: env,
                                                 workingDirectory: runtime.pipeline, log: log, onLine: onLine)
        if result.signal == SIGKILL {
            // Gatekeeper kills processes of an app it has not approved (a quarantined bundle).
            throw PipelineError("macOS stopped the game pipeline (killed). If Hunter's Lantern was just downloaded, open it once with System Settings › Privacy & Security › Open Anyway.")
        }
        return result
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    /// The terminating signal, 0 for a normal exit.
    public var signal: Int32
    public var stdout: String
    public var stderr: String
}

/// Runs a helper process (the pipeline, a PKG tool) to its end, collecting its output.
public enum ProcessRunner {
    public static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                           workingDirectory: URL? = nil, log: FileHandle? = nil,
                           onLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = OutputCollector(log: log, onLine: onLine)
        // At the end of the output the handler is called again and again with no data: it stops
        // itself (the termination handler reads what is left).
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.add(data, stdout: true) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.add(data, stdout: false) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { process in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.add(out.fileHandleForReading.readDataToEndOfFile(), stdout: true)
                    collector.add(err.fileHandleForReading.readDataToEndOfFile(), stdout: false)
                    collector.flush()
                    let signaled = process.terminationReason == .uncaughtSignal
                    continuation.resume(returning: ProcessResult(
                        status: signaled ? -1 : process.terminationStatus,
                        signal: signaled ? process.terminationStatus : 0,
                        stdout: collector.stdout, stderr: collector.stderr))
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Output of a running process, collected from the pipes' handler threads.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data(), pending = Data()
    private let log: FileHandle?
    private let onLine: ((String) -> Void)?

    init(log: FileHandle?, onLine: ((String) -> Void)?) {
        self.log = log
        self.onLine = onLine
    }

    func add(_ data: Data, stdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        // Not write(_:): it raises an Objective-C exception on a full disk. The log is a copy.
        try? log?.write(contentsOf: data)
        if stdout {
            out.append(data)
            guard let onLine else { return }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        } else {
            err.append(data)
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty, let onLine { onLine(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}
