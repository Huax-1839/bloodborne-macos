// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// How a game run ended (D8).
public enum GameOutcome: Equatable, Sendable {
    /// Exit status 0.
    case finished
    /// Exit status 75 (BB_RESTART_EXIT, src/runtime.h): the settings menu's "Apply and restart".
    case restartRequested
    /// Another exit status.
    case failed(status: Int32)
    /// Ended by a signal (a crash: SIGSEGV, SIGABRT, SIGKILL, ...).
    case crashed(signal: Int32)
    /// Stopped by the launcher (cancel()).
    case cancelled
}

/// The game process: started from a LaunchSpec, stdout and stderr in logs/run-<time>.log (the
/// last 10 kept), one instance at a time (a lock file plus a running-process check). Task L1.4.
public final class GameProcess: @unchecked Sendable {
    public init(spec: LaunchSpec, logsDir: URL, lockFile: URL) { fatalError("L1.4") }
    /// Starts the game; the log's URL. Throws when another game instance is running.
    public func start() throws -> URL { fatalError("L1.4") }
    /// Waits for the end.
    public func wait() async -> GameOutcome { fatalError("L1.4") }
    /// Ends the game (SIGTERM, SIGKILL after a grace period).
    public func cancel() { fatalError("L1.4") }
    public var isRunning: Bool { fatalError("L1.4") }
}
