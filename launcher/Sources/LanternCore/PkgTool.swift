// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Why a chosen program is not usable as the PKG tool.
public enum PkgToolError: Error, LocalizedError, Equatable {
    case notFound(URL)
    case notExecutable(URL)
    /// LibOrbisPkg's PkgTool on .NET 6+ leaves stale sectors in the files (scripts/game_check.py).
    case libOrbisPkg
    case unrecognized(String)
    case timedOut
    case cannotRun(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let url):
            return String(localized: "\(url.path) does not exist.", bundle: .module)
        case .notExecutable(let url):
            return String(localized: "\(url.lastPathComponent) is not an executable program.", bundle: .module)
        case .libOrbisPkg:
            return String(localized: "LibOrbisPkg's PkgTool is not supported: on .NET 6 or newer it leaves parts of the files stale, and the game would hang while loading. Use ps4-pkg-tools instead.", bundle: .module)
        case .unrecognized(let name):
            return String(localized: "\(name) is not a known PKG tool. Supported: ps4-pkg-tools (recommended), pkgextract, orbis-pkg-util.", bundle: .module)
        case .timedOut:
            return String(localized: "The program did not answer to --help within 5 seconds.", bundle: .module)
        case .cannotRun(let reason):
            return String(localized: "The program could not be started: \(reason)", bundle: .module)
        }
    }
}

/// An external PKG extractor (D6c). The launcher never downloads or bundles one.
public struct PkgTool: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// ps4-pkg-tools (recommended): `ps4-pkg-tool <pkg> [outdir]`, writes outdir/<TITLE_ID>/.
        case ps4PkgTools
        /// `pkgextract <file.pkg> [-o DIR] [-f]`.
        case pkgextract
        /// `orbis-pkg-util extract <pkg> [-o DIR] [-f] [-q]`.
        case orbisPkgUtil

        public var executableName: String {
            switch self {
            case .ps4PkgTools: return "ps4-pkg-tool"
            case .pkgextract: return "pkgextract"
            case .orbisPkgUtil: return "orbis-pkg-util"
            }
        }

        public var displayName: String {
            switch self {
            case .ps4PkgTools: return "ps4-pkg-tools"
            case .pkgextract: return "pkgextract"
            case .orbisPkgUtil: return "orbis-pkg-util"
            }
        }

        /// The usage text is the only identification: none of them has --version.
        func matches(usage: String) -> Bool {
            usage.lowercased().contains(executableName)
        }

        func arguments(pkg: URL, output: URL) -> [String] {
            switch self {
            case .ps4PkgTools: return [pkg.path, output.path]
            case .pkgextract: return [pkg.path, "-o", output.path, "-f"]
            case .orbisPkgUtil: return ["extract", pkg.path, "-o", output.path, "-f", "-q"]
            }
        }
    }

    public var kind: Kind
    public var executable: URL

    public init(kind: Kind, executable: URL) {
        self.kind = kind
        self.executable = executable
    }

    // MARK: - Finding one

    /// Where tools are installed besides PATH and the user's own choice.
    public static let defaultSystemDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The first usable tool, by name only (nothing is run): `extraPaths` (files or folders the
    /// user chose), PATH, the system folders, then ~/Applications and /Applications (top level
    /// and one level of subfolders' build/ and bin/, for a source build next to the other apps).
    /// ps4-pkg-tools comes before the others within a folder.
    public static func detect(extraPaths: [URL] = [],
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              systemDirectories: [String] = defaultSystemDirectories,
                              applicationsDirectories: [URL]? = nil) -> PkgTool? {
        let fm = FileManager.default
        for url in extraPaths {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let tool = find(in: url) { return tool }
            } else if let tool = tool(at: url) {
                return tool
            }
        }
        var folders = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        folders += systemDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        for folder in folders {
            if let tool = find(in: folder) { return tool }
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fm.homeDirectoryForCurrentUser
        let applications = applicationsDirectories ?? [home.appendingPathComponent("Applications", isDirectory: true),
                                                       URL(fileURLWithPath: "/Applications", isDirectory: true)]
        for folder in applications {
            if let tool = find(in: folder) { return tool }
            let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.path < $1.path }) {
                for sub in ["build", "bin"] {
                    if let tool = find(in: child.appendingPathComponent(sub, isDirectory: true)) { return tool }
                }
            }
        }
        return nil
    }

    private static func find(in folder: URL) -> PkgTool? {
        for kind in Kind.allCases {
            if let tool = tool(at: folder.appendingPathComponent(kind.executableName)) { return tool }
        }
        return nil
    }

    private static func tool(at url: URL) -> PkgTool? {
        guard let kind = kind(named: url.lastPathComponent), isExecutableFile(url) else { return nil }
        return PkgTool(kind: kind, executable: url)
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func kind(named name: String) -> Kind? {
        let lower = name.lowercased()
        return Kind.allCases.first { $0.executableName == lower }
    }

    /// LibOrbisPkg's PkgTool (the .NET build, a `dotnet PkgTool.Core.dll` call or the framework-
    /// dependent apphost).
    static func isLibOrbisPkg(named name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "dotnet" || lower.hasSuffix(".dll") || lower == "pkgtool" || lower.hasPrefix("pkgtool.")
    }

    // MARK: - Validating a chosen one

    /// A user-chosen program: refused when it is LibOrbisPkg or no executable, else run with
    /// --help (then -h) for 5 s and identified by its usage text.
    public static func validate(_ url: URL) -> Result<PkgTool, PkgToolError> {
        let name = url.lastPathComponent
        if isLibOrbisPkg(named: name) { return .failure(.libOrbisPkg) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .failure(.notFound(url)) }
        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            return .failure(.notExecutable(url))
        }
        var usage = ""
        for flag in ["--help", "-h"] {
            switch helpText(url, flag: flag) {
            case .failure(let error): return .failure(error)
            case .success(let text): usage = text
            }
            if usage.contains("LibOrbisPkg") || Kind.allCases.contains(where: { $0.matches(usage: usage) }) { break }
        }
        if usage.contains("LibOrbisPkg") { return .failure(.libOrbisPkg) }
        let named = kind(named: name)
        if let named {
            return named.matches(usage: usage) ? .success(PkgTool(kind: named, executable: url)) : .failure(.unrecognized(name))
        }
        // A renamed program: the usage text says which it is.
        if let kind = Kind.allCases.first(where: { $0.matches(usage: usage) }) {
            return .success(PkgTool(kind: kind, executable: url))
        }
        return .failure(.unrecognized(name))
    }

    /// stdout and stderr of `url flag`, killed after 5 s.
    private static func helpText(_ url: URL, flag: String, timeout: TimeInterval = 5) -> Result<String, PkgToolError> {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("lantern-help-" + UUID().uuidString, isDirectory: true)
        let output = directory.appendingPathComponent("out.txt")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            fm.createFile(atPath: output.path, contents: nil)
        } catch {
            return .failure(.cannotRun(error.localizedDescription))
        }
        defer { try? fm.removeItem(at: directory) }
        guard let handle = try? FileHandle(forWritingTo: output) else { return .failure(.cannotRun(output.path)) }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = url
        process.arguments = [flag]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return .failure(.cannotRun(error.localizedDescription)) }
        let end = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > end {
                process.terminate()
                return .failure(.timedOut)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try? handle.synchronize()
        return .success((try? String(contentsOf: output, encoding: .utf8)) ?? "")
    }

    // MARK: - Extracting

    /// Extracts `pkg` into the fresh folder `output` (created here, must be empty if it exists)
    /// and returns the app folder in it. `progress` gets the fraction (bytes written so far
    /// against the PKG's size) twice a second. On failure or cancellation the output folder is
    /// deleted again (a failed ps4-pkg-tool leaves an empty title folder behind).
    public func extract(pkg: URL, into output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        if let existing = try? fm.contentsOfDirectory(atPath: output.path), !existing.isEmpty {
            throw ImportError.destinationExists(output)
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let pkgSize = ((try? fm.attributesOfItem(atPath: pkg.path))?[.size] as? NSNumber)?.int64Value ?? 0

        let poller = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                if pkgSize > 0 { progress(min(0.99, Double(FileWalk.size(of: output)) / Double(pkgSize))) }
            }
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(executable, arguments: kind.arguments(pkg: pkg, output: output),
                                                 workingDirectory: output)
        } catch {
            poller.cancel()
            try? fm.removeItem(at: output)
            throw ImportError.cannotStart(tool: kind.displayName, reason: error.localizedDescription)
        }
        poller.cancel()
        if Task.isCancelled {
            try? fm.removeItem(at: output)
            throw CancellationError()
        }
        guard result.status == 0 else {
            try? fm.removeItem(at: output)
            let text = result.stderr.isEmpty ? result.stdout : result.stderr
            throw ImportError.extractionFailed(tool: kind.displayName,
                                               details: String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1000)))
        }
        guard let app = GameFolder.locate(output) else {
            try? fm.removeItem(at: output)
            throw ImportError.nothingExtracted(output)
        }
        progress(1)
        return app
    }
}

/// The game imported from PKGs: the folder and its quick check.
public struct ImportedGame: Equatable, Sendable {
    public var folder: URL
    public var check: GameCheck
}

extension GameImporter {
    public enum Phase: Sendable, Equatable {
        case extractingBase, extractingUpdate, merging, checking
    }

    /// Kept free on the games volume on top of the PKGs' sizes (the extracted files are about
    /// 94% of a PKG, the merge costs next to nothing).
    public static let importMargin: Int64 = 2 << 30

    /// Path (c) of D6: extracts the base PKG and the update PKG (when given) into
    /// dirs.gamesDir/.import-<uuid>/ (left over after a crash: DataDirs.removeLeftovers), merges them into dirs.gamesDir/<TITLE>-<version> (a unique
    /// name), removes the scratch folder and runs the quick check. The caller registers the
    /// folder; a check problem (`ImportedGame.check`) is the caller's to show. Cancelling the
    /// task removes everything made. `progress` gets the phase and its fraction.
    public static func importPKGs(base: URL, update: URL?, tool: PkgTool, dirs: DataDirs, pipeline: Pipeline,
                                  progress: @escaping @Sendable (Phase, Double) -> Void) async throws -> ImportedGame {
        try await importPKGs(base: base, update: update, tool: tool, dirs: dirs, pipeline: pipeline,
                             availableCapacity: nil, progress: progress)
    }

    /// `availableCapacity` replaces the volume's free space (tests).
    static func importPKGs(base: URL, update: URL?, tool: PkgTool, dirs: DataDirs, pipeline: Pipeline,
                           availableCapacity: Int64?,
                           progress: @escaping @Sendable (Phase, Double) -> Void) async throws -> ImportedGame {
        let fm = FileManager.default
        let games = dirs.gamesDir
        try fm.createDirectory(at: games, withIntermediateDirectories: true)

        func size(_ url: URL) -> Int64 { ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        let needed = size(base) + (update.map(size) ?? 0) + importMargin
        if let available = availableCapacity ?? GameImporter.availableCapacity(at: games), available < needed {
            throw ImportError.notEnoughSpace(needed: needed, available: available)
        }

        let work = games.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let baseApp = try await tool.extract(pkg: base, into: work.appendingPathComponent("base", isDirectory: true)) {
            progress(.extractingBase, $0)
        }
        guard let update else {
            // Checked before it leaves the scratch folder (a failed check leaves nothing) and
            // named after its own version: a base game is no 1.09.
            progress(.checking, 0)
            let check = try await pipeline.quickCheck(game: baseApp)
            try Task.checkCancellation()
            let target = uniqueFolder(in: games, name: folderName(title: check.title, version: check.version,
                                                                  fallback: baseApp.lastPathComponent))
            try fm.moveItem(at: baseApp, to: target)
            return ImportedGame(folder: target, check: check)
        }
        let updateApp = try await tool.extract(pkg: update, into: work.appendingPathComponent("update", isDirectory: true)) {
            progress(.extractingUpdate, $0)
        }

        // The merged folder is named after the update's title and version.
        let updateCheck = try? await pipeline.quickCheck(game: updateApp)
        let target = uniqueFolder(in: games, name: folderName(title: updateCheck?.title, version: updateCheck?.version,
                                                              fallback: baseApp.lastPathComponent))
        try await merge(base: baseApp, update: updateApp, into: target, availableCapacity: availableCapacity, entryHook: nil) { done, total in
            progress(.merging, total > 0 ? Double(done) / Double(total) : 1)
        }
        try? fm.removeItem(at: work)
        progress(.checking, 0)
        do {
            let check = try await pipeline.quickCheck(game: target)
            try Task.checkCancellation()
            return ImportedGame(folder: target, check: check)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// "CUSA03173-1.09": the title id and the version without the sfo's leading zero ("01.09").
    static func folderName(title: String?, version: String?, fallback: String) -> String {
        func clean(_ text: String) -> String {
            String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }.map(Character.init))
        }
        let title = title.flatMap { $0 == "?" ? nil : clean($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? clean(fallback)
        var version = (version == nil || version == "?") ? "1.09" : clean(version!)
        let parts = version.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2, let major = Int(parts[0]) { version = "\(major).\(parts[1])" }
        return title.isEmpty ? version : "\(title)-\(version)"
    }

    static func uniqueFolder(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name, isDirectory: true)
        var number = 2
        var info = stat()
        while lstat(candidate.path, &info) == 0 {
            candidate = directory.appendingPathComponent("\(name)-\(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }
}
