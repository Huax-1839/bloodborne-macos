// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// How a game run ended (D8).
public enum GameOutcome: Equatable, Sendable {
    /// Exit status 0.
    case finished
    /// Exit status 75 (BB_RESTART_EXIT, src/runtime.h): the game asks to be started again (runtime_restart).
    case restartRequested
    /// Another exit status.
    case failed(status: Int32)
    /// Ended by a signal (a crash: SIGSEGV, SIGABRT, SIGKILL, ...).
    case crashed(signal: Int32)
    /// Stopped by the launcher (cancel()).
    case cancelled
}

/// Why start() refused or failed.
public enum GameProcessError: Error, Equatable, LocalizedError, CustomStringConvertible {
    /// The lock file is held: another launcher (or another GameProcess) runs a game. `pid` is the
    /// game's pid when the lock file names it.
    case alreadyRunning(pid: Int32?)
    /// A `bb-probe` process runs that this GameProcess did not start (macos/run.sh, a bench).
    case externalGameRunning(pid: Int32)
    /// start() was called a second time on the same object.
    case alreadyStarted
    /// The lock file, the log folder or the log file could not be used.
    case setupFailed(String)
    /// The executable could not be spawned.
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let pid?):
            return String(localized: "Another game is already running (pid \(Int(pid))).", bundle: .module)
        case .alreadyRunning(nil):
            return String(localized: "Another game is already running.", bundle: .module)
        case .externalGameRunning(let pid):
            return String(localized: "A game process (bb-probe, pid \(Int(pid))) is already running.", bundle: .module)
        case .alreadyStarted:
            return String(localized: "This game process was already started.", bundle: .module)
        case .setupFailed(let message):
            return String(localized: "Could not prepare the game start: \(message)", bundle: .module)
        case .launchFailed(let message):
            return String(localized: "Could not start the game: \(message)", bundle: .module)
        }
    }

    public var description: String { errorDescription ?? "" }
}

/// The game process: started from a LaunchSpec, stdout and stderr in logs/run-<time>.log (the
/// last 10 kept), one instance at a time (a lock file plus a running-process check). Task L1.4.
///
/// Locking: start() takes the one-game lock (`GameLock`) and keeps it until the process ended or
/// start() failed; the game's pid is written into the file. A lock the caller already holds
/// (Launcher holds it across the whole launch, R6) is used instead and stays with the caller. The
/// process check looks for any process whose executable is named `bb-probe`.
///
/// wait() may be called any number of times, from any thread or the main actor: every awaiter
/// gets the same outcome, and a call after the end returns at once. Calling it before start()
/// returns `.failed(status: -1)`.
public final class GameProcess: @unchecked Sendable {
    /// BB_RESTART_EXIT in src/runtime.h.
    public static let restartExitCode: Int32 = 75
    /// Seconds between SIGTERM and SIGKILL in cancel().
    public static let defaultKillGrace: TimeInterval = 5
    /// Logs kept in the logs folder (run-*.log).
    public static let keptLogs = 10
    /// The game's executable name (the running-process check).
    public static let gameProcessName = "bb-probe"

    private let spec: LaunchSpec
    private let logsDir: URL
    private let lockFile: URL
    /// A lock the caller holds; nil: start() takes its own.
    private let heldLock: GameLock?
    private let killGrace: TimeInterval
    private let probeName: String

    private let mutex = NSLock()
    // All below under `mutex`.
    private var started = false
    private var process: Process?
    /// The lock while the game runs (taken by start() or the caller's).
    private var lock: GameLock?
    private var exited = false
    private var cancelled = false
    private var outcome: GameOutcome?
    private var waiters: [CheckedContinuation<GameOutcome, Never>] = []

    public init(spec: LaunchSpec, logsDir: URL, lockFile: URL) {
        self.spec = spec
        self.logsDir = logsDir
        self.lockFile = lockFile
        self.heldLock = nil
        self.killGrace = Self.defaultKillGrace
        self.probeName = Self.gameProcessName
    }

    /// A game started under a lock the caller holds (and releases).
    public init(spec: LaunchSpec, logsDir: URL, lock: GameLock) {
        self.spec = spec
        self.logsDir = logsDir
        self.lockFile = lock.url
        self.heldLock = lock
        self.killGrace = Self.defaultKillGrace
        self.probeName = Self.gameProcessName
    }

    /// For tests: a short SIGKILL grace and another process name to look for.
    init(spec: LaunchSpec, logsDir: URL, lockFile: URL, killGrace: TimeInterval, probeName: String) {
        self.spec = spec
        self.logsDir = logsDir
        self.lockFile = lockFile
        self.heldLock = nil
        self.killGrace = killGrace
        self.probeName = probeName
    }

    /// The game's pid while it runs (and after, until the object goes away); nil before start().
    public var pid: Int32? {
        mutex.lock()
        defer { mutex.unlock() }
        return process.map { $0.processIdentifier }
    }

    public var isRunning: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return process != nil && !exited
    }

    /// Starts the game; the log's URL. Throws when another game instance is running.
    public func start() throws -> URL {
        mutex.lock()
        defer { mutex.unlock() }
        if started { throw GameProcessError.alreadyStarted }

        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            throw GameProcessError.setupFailed(error.localizedDescription)
        }

        let lock = try heldLock ?? GameLock.acquire(lockFile)
        var succeeded = false
        defer {
            if !succeeded && heldLock == nil { lock.release() }
        }
        if let other = Self.findProcess(named: probeName) {
            throw GameProcessError.externalGameRunning(pid: other)
        }

        let (logURL, logFD) = try Self.createLog(in: logsDir)
        defer { close(logFD) }  // the child has its own duplicates

        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = ExpertVariables.inheritedEnvironment.merging(spec.environment) { _, new in new }
        process.currentDirectoryURL = spec.workingDirectory
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null") ?? FileHandle.nullDevice
        let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: false)
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { proc in self.processEnded(proc) }  // released in processEnded
        do {
            try process.run()
        } catch {
            throw GameProcessError.launchFailed(error.localizedDescription)
        }

        started = true
        succeeded = true
        self.process = process
        self.lock = lock
        lock.write(pid: process.processIdentifier)

        Self.pruneLogs(in: logsDir, keeping: logURL)
        return logURL
    }

    /// Waits for the end; the same outcome for every caller.
    public func wait() async -> GameOutcome {
        await withCheckedContinuation { continuation in
            register(continuation)
        }
    }

    private func register(_ continuation: CheckedContinuation<GameOutcome, Never>) {
        mutex.lock()
        if let outcome {
            mutex.unlock()
            continuation.resume(returning: outcome)
        } else if !started {
            mutex.unlock()
            continuation.resume(returning: .failed(status: -1))
        } else {
            waiters.append(continuation)
            mutex.unlock()
        }
    }

    /// Ends the game (SIGTERM, SIGKILL after a grace period). No effect when it is not running;
    /// the outcome of a run that ends after this call is `.cancelled`.
    public func cancel() {
        mutex.lock()
        guard let process, !exited else {
            mutex.unlock()
            return
        }
        cancelled = true
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        mutex.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [weak self] in
            guard let self else { return }
            self.mutex.lock()
            defer { self.mutex.unlock() }
            // `exited` is set under the same mutex right after the child was reaped, so the pid
            // still belongs to the child here.
            if !self.exited { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Process end

    private func processEnded(_ proc: Process) {
        proc.terminationHandler = nil  // breaks the cycle with self
        mutex.lock()
        exited = true
        let result: GameOutcome
        if cancelled {
            result = .cancelled
        } else if proc.terminationReason == .uncaughtSignal {
            result = .crashed(signal: proc.terminationStatus)
        } else {
            switch proc.terminationStatus {
            case 0: result = .finished
            case Self.restartExitCode: result = .restartRequested
            default: result = .failed(status: proc.terminationStatus)
            }
        }
        outcome = result
        if let lock {
            if heldLock == nil { lock.release() } else { lock.write(pid: nil) }
            self.lock = nil
        }
        let pending = waiters
        waiters = []
        mutex.unlock()
        for waiter in pending { waiter.resume(returning: result) }
    }

    // MARK: - Helpers

    /// The pid of a process whose executable is called `name` (libproc, no pgrep).
    static func findProcess(named name: String) -> Int32? {
        let ownPid = getpid()
        var capacity = Int(proc_listallpids(nil, 0))
        if capacity <= 0 { return nil }
        capacity += 64  // processes started in between
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        if count <= 0 { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(count) where pid > 0 && pid != ownPid {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if length > 0 {
                let path = String(cString: pathBuffer)
                if (path as NSString).lastPathComponent == name { return pid }
            } else {
                // Not readable (another user's process): fall back to the short process name.
                var nameBuffer = [CChar](repeating: 0, count: 64)
                if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0, String(cString: nameBuffer) == name {
                    return pid
                }
            }
        }
        return nil
    }

    /// Creates logs/run-YYYYMMDD-HHMMSS.log (-2, -3, ... when it exists), opened for appending.
    private static func createLog(in dir: URL) throws -> (URL, Int32) {
        var now = time(nil)
        var parts = tm()
        localtime_r(&now, &parts)
        var stamp = [CChar](repeating: 0, count: 32)
        strftime(&stamp, stamp.count, "%Y%m%d-%H%M%S", &parts)
        let base = "run-" + String(cString: stamp)
        for attempt in 1...1000 {
            let name = attempt == 1 ? "\(base).log" : "\(base)-\(attempt).log"
            let url = dir.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
            if fd >= 0 { return (url, fd) }
            if errno != EEXIST { throw GameProcessError.setupFailed("log file: \(String(cString: strerror(errno)))") }
        }
        throw GameProcessError.setupFailed("log file: no free name")
    }

    /// A past run, read from its log: started at the time in the log's name, ended at the log's
    /// last write.
    public struct Session: Equatable, Sendable {
        public var log: URL
        public var start: Date
        public var end: Date
        public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    /// The newest run in the logs folder (the home page's "last hunt"), nil when there is none.
    public static func lastSession(logsDir: URL) -> Session? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyyMMdd-HHmmss"
        var sessions: [(session: Session, attempt: Int)] = []
        for url in urls where url.lastPathComponent.hasPrefix("run-") && url.pathExtension == "log" {
            // run-YYYYMMDD-HHMMSS.log or run-YYYYMMDD-HHMMSS-<n>.log
            let name = url.deletingPathExtension().lastPathComponent.dropFirst(4)
            guard let start = parser.date(from: String(name.prefix(15))),
                  let end = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            let attempt = Int(name.dropFirst(16)) ?? 1
            sessions.append((Session(log: url, start: start, end: end), attempt))
        }
        return sessions.max {
            $0.session.start != $1.session.start ? $0.session.start < $1.session.start : $0.attempt < $1.attempt
        }?.session
    }

    /// Deletes the oldest run-*.log files so that `keptLogs` remain, `current` among them.
    private static func pruneLogs(in dir: URL, keeping current: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        var logs: [(url: URL, date: Date)] = []
        for url in urls where url.lastPathComponent.hasPrefix("run-") && url.pathExtension == "log"
            && url.lastPathComponent != current.lastPathComponent {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            logs.append((url, date ?? .distantPast))
        }
        logs.sort { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
        for old in logs.dropFirst(keptLogs - 1) { try? fm.removeItem(at: old.url) }
    }
}

/// The one-game lock: an exclusive non-blocking flock on the lock file (opened O_CLOEXEC, so the
/// game does not inherit it), with the running game's pid in the file. Released by `release()` or
/// when the object goes away.
public final class GameLock: @unchecked Sendable {
    public let url: URL
    private let mutex = NSLock()
    private var fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit { release() }

    /// Takes the lock without blocking; `GameProcessError.alreadyRunning` when it is held.
    public static func acquire(_ url: URL) throws -> GameLock {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw GameProcessError.setupFailed(error.localizedDescription)
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if fd < 0 { throw GameProcessError.setupFailed("lock file: \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let reason = errno
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = pread(fd, &buffer, buffer.count, 0)
            close(fd)
            if reason == EWOULDBLOCK {
                let text = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
                throw GameProcessError.alreadyRunning(pid: Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            throw GameProcessError.setupFailed("lock file: \(String(cString: strerror(reason)))")
        }
        return GameLock(url: url, fd: fd)
    }

    /// The running game's pid into the file (nil empties it: between restarts).
    func write(pid: Int32?) {
        mutex.withLock {
            guard fd >= 0 else { return }
            ftruncate(fd, 0)
            if let pid { _ = "\(pid)\n".withCString { pwrite(fd, $0, strlen($0), 0) } }
        }
    }

    public func release() {
        mutex.withLock {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }
}
