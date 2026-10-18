// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class GameProcessTests: XCTestCase {
    private var dir: URL!
    private var logsDir: URL { dir.appendingPathComponent("logs") }
    private var lockFile: URL { dir.appendingPathComponent("game.lock") }
    /// Never "bb-probe": a real game running on the machine must not disturb the tests.
    private let probeName = "fake-bbprobe-" + UUID().uuidString

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gameprocess-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// R19: the game gets BB_*/MVK_*/ROSETTA_* only from the spec, never from the launcher's own
    /// environment; other variables (HOME, PATH) still reach it.
    func testGameVariablesComeOnlyFromTheSpec() async throws {
        setenv("BB_R19_INHERITED", "1", 1)
        setenv("MVK_R19_INHERITED", "1", 1)
        setenv("BB_R19_OVERRIDDEN", "launcher", 1)
        defer {
            for name in ["BB_R19_INHERITED", "MVK_R19_INHERITED", "BB_R19_OVERRIDDEN"] { unsetenv(name) }
        }
        let out = dir.appendingPathComponent("env.txt")
        let game = process(try script("env.sh", "env > '\(out.path)'"), environment: ["BB_R19_OVERRIDDEN": "spec"])
        _ = try game.start()
        let outcome = await game.wait()
        XCTAssertEqual(outcome, .finished)
        let lines = Set(logText(out).split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("BB_R19_OVERRIDDEN=spec"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("BB_R19_INHERITED=") || $0.hasPrefix("MVK_R19_INHERITED=") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("HOME=") })
    }

    // MARK: - Helpers

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func process(_ executable: URL, arguments: [String] = [], environment: [String: String] = [:],
                         cwd: URL? = nil, lock: URL? = nil, grace: TimeInterval = 0.3,
                         probe: String? = nil) -> GameProcess {
        let spec = LaunchSpec(steps: [], executable: executable, arguments: arguments, environment: environment,
                              workingDirectory: cwd ?? dir)
        return GameProcess(spec: spec, logsDir: logsDir, lockFile: lock ?? lockFile, killGrace: grace,
                           probeName: probe ?? probeName)
    }

    private func outcome(ofScript body: String) async throws -> GameOutcome {
        let game = process(try script("fake.sh", body))
        _ = try game.start()
        return await game.wait()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return XCTFail("timeout waiting for \(what)") }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// realpath(3): /var/folders resolves to /private/var/folders, which URL's resolvingSymlinksInPath
    /// does not do.
    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func logText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A copy of /bin/sleep named `name`: a process whose executable has that name (a script would
    /// show up as bash). Copied binaries need a fresh ad-hoc signature.
    private func namedSleep(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: url.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", url.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        return url
    }

    // MARK: - Outcomes

    func testExitZeroIsFinished() async throws {
        let result = try await outcome(ofScript: "exit 0")
        XCTAssertEqual(result, .finished)
    }

    func testExit75IsRestartRequested() async throws {
        let result = try await outcome(ofScript: "exit 75")
        XCTAssertEqual(result, .restartRequested)
    }

    func testOtherStatusIsFailed() async throws {
        let result = try await outcome(ofScript: "exit 3")
        XCTAssertEqual(result, .failed(status: 3))
    }

    func testSignalIsCrashed() async throws {
        let result = try await outcome(ofScript: "kill -SEGV $$\nsleep 5")
        XCTAssertEqual(result, .crashed(signal: SIGSEGV))
    }

    func testStateAroundTheRun() async throws {
        let game = process(try script("fake.sh", "sleep 0.3"))
        XCTAssertFalse(game.isRunning)
        XCTAssertNil(game.pid)
        let early = await game.wait()
        XCTAssertEqual(early, .failed(status: -1))
        _ = try game.start()
        XCTAssertTrue(game.isRunning)
        XCTAssertNotNil(game.pid)
        XCTAssertThrowsError(try game.start()) { XCTAssertEqual($0 as? GameProcessError, .alreadyStarted) }
        let result = await game.wait()
        XCTAssertEqual(result, .finished)
        XCTAssertFalse(game.isRunning)
        let again = await game.wait()  // after the end: the same outcome at once
        XCTAssertEqual(again, .finished)
    }

    func testSeveralAwaitersGetTheOutcome() async throws {
        let game = process(try script("fake.sh", "sleep 0.5\nexit 75"))
        _ = try game.start()
        async let a = game.wait()
        async let b = game.wait()
        async let c = game.wait()
        let results = await [a, b, c]
        XCTAssertEqual(results, [.restartRequested, .restartRequested, .restartRequested])
    }

    // MARK: - Log, environment, cwd

    func testLogHasBothStreamsEnvironmentAndCwd() async throws {
        let cwd = dir.appendingPathComponent("work dir")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let exe = try script("fake.sh", """
            echo "out-line"
            echo "err-line" >&2
            echo "BB_TEST=$BB_TEST"
            echo "PATH_SET=${PATH:+yes}"
            echo "HOME_SET=${HOME:+yes}"
            echo "ARGS=$1|$2"
            echo "CWD=$(pwd -P)"
            read -t 1 line && echo "stdin-had-data" || echo "stdin-empty"
            """)
        let game = process(exe, arguments: ["a b", "c"], environment: ["BB_TEST": "value 1"], cwd: cwd)
        let log = try game.start()
        let result = await game.wait()
        XCTAssertEqual(result, .finished)
        let text = logText(log)
        XCTAssertTrue(text.contains("out-line\n"), text)
        XCTAssertTrue(text.contains("err-line\n"), text)
        XCTAssertTrue(text.contains("BB_TEST=value 1\n"), text)
        XCTAssertTrue(text.contains("PATH_SET=yes\n"), text)  // the launcher's own environment is kept
        XCTAssertTrue(text.contains("HOME_SET=yes\n"), text)
        XCTAssertTrue(text.contains("ARGS=a b|c\n"), text)
        XCTAssertTrue(text.contains("CWD=" + realPath(cwd) + "\n"), text)
        XCTAssertTrue(text.contains("stdin-empty\n"), text)
        XCTAssertTrue(log.lastPathComponent.hasPrefix("run-"))
        XCTAssertEqual(log.deletingLastPathComponent().standardizedFileURL, logsDir.standardizedFileURL)
    }

    func testSpecEnvironmentOverridesLauncherEnvironment() async throws {
        let exe = try script("fake.sh", "echo \"HOME=$HOME\"")
        let game = process(exe, environment: ["HOME": "/nonexistent-home"])
        let log = try game.start()
        _ = await game.wait()
        XCTAssertTrue(logText(log).contains("HOME=/nonexistent-home\n"))
    }

    func testLogNamesAreUnique() async throws {
        let exe = try script("fake.sh", "echo hi")
        var logs: [URL] = []
        for _ in 0..<3 {
            let game = process(exe)
            logs.append(try game.start())
            _ = await game.wait()
        }
        XCTAssertEqual(Set(logs.map(\.lastPathComponent)).count, 3)
        XCTAssertTrue(logs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testLogRotationKeepsTenAndOnlyRunLogs() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let base = Date().addingTimeInterval(-10_000)
        for i in 0..<12 {
            let url = logsDir.appendingPathComponent(String(format: "run-20200101-0000%02d.log", i))
            try "old".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: base.addingTimeInterval(Double(i) * 10)], ofItemAtPath: url.path)
        }
        for other in ["notes.txt", "other.log", "run-keep.txt"] {
            try "x".write(to: logsDir.appendingPathComponent(other), atomically: true, encoding: .utf8)
        }
        let game = process(try script("fake.sh", "echo hi"))
        let log = try game.start()
        _ = await game.wait()

        let names = try fm.contentsOfDirectory(atPath: logsDir.path)
        let runLogs = names.filter { $0.hasPrefix("run-") && $0.hasSuffix(".log") }.sorted()
        XCTAssertEqual(runLogs.count, 10, "\(runLogs)")
        XCTAssertTrue(runLogs.contains(log.lastPathComponent))
        // The newest nine old ones (index 3...11) stay, the oldest three (0...2) are gone.
        XCTAssertFalse(runLogs.contains("run-20200101-000000.log"))
        XCTAssertFalse(runLogs.contains("run-20200101-000002.log"))
        XCTAssertTrue(runLogs.contains("run-20200101-000003.log"))
        XCTAssertTrue(runLogs.contains("run-20200101-000011.log"))
        for other in ["notes.txt", "other.log", "run-keep.txt"] {
            XCTAssertTrue(names.contains(other), other)
        }
    }

    // MARK: - Cancel

    func testCancelEndsWithSigterm() async throws {
        let game = process(try script("fake.sh", "echo ready\nexec sleep 30"), grace: 30)
        let log = try game.start()
        waitUntil("the script to start") { logText(log).contains("ready") }
        let started = Date()
        game.cancel()
        let result = await game.wait()
        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(game.isRunning)
    }

    func testCancelFallsBackToSigkill() async throws {
        let game = process(try script("fake.sh", """
            trap '' TERM
            echo ready
            while true; do sleep 0.2; done
            """), grace: 0.5)
        let log = try game.start()
        waitUntil("the trap") { logText(log).contains("ready") }
        let started = Date()
        game.cancel()
        let result = await game.wait()
        XCTAssertEqual(result, .cancelled)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)  // it ignored SIGTERM
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancelWithoutRunIsHarmless() async throws {
        let game = process(try script("fake.sh", "exit 0"))
        game.cancel()  // not started
        _ = try game.start()
        let result = await game.wait()
        XCTAssertEqual(result, .finished)
        game.cancel()  // already ended
        let again = await game.wait()
        XCTAssertEqual(again, .finished)
    }

    // MARK: - Single instance

    func testSecondInstanceWithSameLockFileIsRefused() async throws {
        let first = process(try script("fake.sh", "echo ready\nexec sleep 30"), grace: 5)
        let log = try first.start()
        waitUntil("the script to start") { logText(log).contains("ready") }

        let second = process(try script("fake2.sh", "exit 0"))
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? GameProcessError, .alreadyRunning(pid: first.pid))
        }
        XCTAssertFalse(second.isRunning)

        first.cancel()
        let result = await first.wait()
        XCTAssertEqual(result, .cancelled)

        // The lock is free once the first ended; the refused attempt left nothing behind.
        _ = try second.start()
        let again = await second.wait()
        XCTAssertEqual(again, .finished)
    }

    func testFailedLaunchReleasesTheLock() async throws {
        let missing = process(dir.appendingPathComponent("does-not-exist"))
        XCTAssertThrowsError(try missing.start()) { error in
            guard case .launchFailed = error as? GameProcessError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(missing.isRunning)
        let game = process(try script("fake.sh", "exit 0"))
        _ = try game.start()
        let result = await game.wait()
        XCTAssertEqual(result, .finished)
    }

    func testRunningProbeProcessIsRefused() async throws {
        // A "game" whose executable is named like the probe, started on its own lock file.
        let exe = try namedSleep(probeName)
        let other = process(exe, arguments: ["30"], lock: dir.appendingPathComponent("other.lock"),
                            probe: "never-running-" + UUID().uuidString)
        _ = try other.start()
        let otherPid = try XCTUnwrap(other.pid)

        let game = process(try script("fake.sh", "exit 0"))
        XCTAssertThrowsError(try game.start()) { error in
            XCTAssertEqual(error as? GameProcessError, .externalGameRunning(pid: otherPid))
        }
        XCTAssertFalse(game.isRunning)

        other.cancel()
        let result = await other.wait()
        XCTAssertEqual(result, .cancelled)

        // Gone: the same check passes, and the refused start did not keep the lock.
        let retry = process(try script("fake3.sh", "exit 0"))
        _ = try retry.start()
        let finished = await retry.wait()
        XCTAssertEqual(finished, .finished)
    }

    /// The home page's last hunt: the newest log by the time in its name, ended at its last write.
    func testLastSessionIsTheNewestLog() throws {
        XCTAssertNil(GameProcess.lastSession(logsDir: logsDir))
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let fm = FileManager.default
        func log(_ name: String, endingAt end: Date) throws {
            let url = logsDir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: end], ofItemAtPath: url.path)
        }
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 17, minute: 18, second: 5))!
        try log("run-20261017-210000.log", endingAt: start.addingTimeInterval(-3600))
        try log("run-20261018-171805.log", endingAt: start.addingTimeInterval(8040))
        try log("notes.txt", endingAt: start.addingTimeInterval(99999))
        let session = try XCTUnwrap(GameProcess.lastSession(logsDir: logsDir))
        XCTAssertEqual(session.log.lastPathComponent, "run-20261018-171805.log")
        XCTAssertEqual(session.start, start)
        XCTAssertEqual(session.duration, 8040, accuracy: 1)
        // A second run in the same second gets "-2" and is the newer one.
        try log("run-20261018-171805-2.log", endingAt: start.addingTimeInterval(60))
        XCTAssertEqual(GameProcess.lastSession(logsDir: logsDir)?.log.lastPathComponent, "run-20261018-171805-2.log")
        XCTAssertEqual(GameProcess.sessions(logsDir: logsDir).map(\.log.lastPathComponent),
                       ["run-20261018-171805-2.log", "run-20261018-171805.log", "run-20261017-210000.log"])
        XCTAssertEqual(GameProcess.sessions(logsDir: logsDir, limit: 2).count, 2)
    }
}
