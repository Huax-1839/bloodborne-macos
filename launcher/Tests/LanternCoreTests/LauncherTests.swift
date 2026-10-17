// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// Launcher.launch with a fake game: the profile's keys reach bbport.ini, a restart (exit 75)
/// starts the game again without a new backup, and an effect the game's menu changed comes back
/// as a profile change (D7, L3.4).
final class LauncherTests: XCTestCase {
    func testRestartAndInGameChangeComesBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dirs = DataDirs(root: root.appendingPathComponent("data"))
        let game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("eboot".utf8).write(to: game.appendingPathComponent("eboot.bin"))
        // The fake game: the first run expects the profile's effect_dof=0, turns depth of field on
        // in the ini (as the menu would) and asks for a restart; the second run expects the game's
        // change to have survived the restart (the profile's keys are written once per launch).
        let probe = root.appendingPathComponent("fake-game.sh")
        let marker = root.appendingPathComponent("restarted")
        try """
        #!/bin/bash
        if [[ ! -f '\(marker.path)' ]]; then
            grep -q '^effect_dof=0$' "$BB_CONFIG" || exit 3
            touch '\(marker.path)'
            sed -i '' 's/^effect_dof=0$/effect_dof=1/' "$BB_CONFIG"
            exit 75
        fi
        grep -q '^effect_dof=1$' "$BB_CONFIG" || exit 4
        exit 0
        """.write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)

        let runtime = Runtime(probe: probe, pipeline: root, python: URL(fileURLWithPath: "/usr/bin/true"))
        let launcher = Launcher(dirs: dirs, runtime: runtime, pipeline: FakePipeline())
        let backups = LockedBox(0)
        launcher.backup = { _ in backups.mutate { $0 += 1 } }
        let phases = LockedBox<[LaunchPhase]>([])
        let gameEntry = Game(path: game, check: GameCheck(problem: nil, title: "CUSA03173", version: "01.09", imageSHA256: "abc"))

        let result = try await launcher.launch(game: gameEntry, profile: .air, settings: LauncherSettings()) { phase in
            phases.mutate { $0.append(phase) }
        }
        XCTAssertEqual(result.outcome, .finished)
        XCTAssertEqual(backups.value, 1, "one backup per launch, none for the restart")
        XCTAssertTrue(phases.value.contains(.restarting))
        XCTAssertEqual(result.changedProfileKeys, ["effect_dof": "1"])
        let ini = try IniFile.load(dirs.iniFile)
        XCTAssertEqual(ini["effect_dof"], "1")
        XCTAssertEqual(ini["model_lod"], "1")
    }

    /// A fake game in a scratch folder: `body` is its script.
    private func fakeGame(_ body: String) throws -> (root: URL, dirs: DataDirs, runtime: Runtime, game: Game) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("eboot".utf8).write(to: folder.appendingPathComponent("eboot.bin"))
        let probe = root.appendingPathComponent("fake-game.sh")
        try ("#!/bin/bash\n" + body + "\n").write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        let runtime = Runtime(probe: probe, pipeline: root, python: URL(fileURLWithPath: "/usr/bin/true"))
        let game = Game(path: folder, check: GameCheck(problem: nil, title: "CUSA03173", version: "01.09", imageSHA256: "abc"))
        return (root, DataDirs(root: root.appendingPathComponent("data")), runtime, game)
    }

    /// R9: a display key one preset writes does not reach the next one; a value the game's menu
    /// left in the ini is reset by the preset too.
    func testPresetsDoNotInheritEachOthersDisplayKeys() async throws {
        let fake = try fakeGame("exit 0")
        let launcher = Launcher(dirs: fake.dirs, runtime: fake.runtime, pipeline: FakePipeline())
        _ = try await launcher.launch(game: fake.game, profile: .max, settings: LauncherSettings()) { _ in }
        XCTAssertEqual(try IniFile.load(fake.dirs.iniFile)["upscaler"], "metalfx")
        var ini = try IniFile.load(fake.dirs.iniFile)
        ini.set([("preset", "3")]) // changed in the game's menu
        try ini.write(to: fake.dirs.iniFile)

        _ = try await launcher.launch(game: fake.game, profile: .vanilla, settings: LauncherSettings()) { _ in }
        let after = try IniFile.load(fake.dirs.iniFile)
        XCTAssertEqual(after["upscaler"], "fsr3")
        XCTAssertEqual(after["preset"], "0")
        for preset in Profile.builtins {
            XCTAssertTrue(Profile.displayKeys.isSubset(of: preset.iniValues.keys), preset.name)
        }
    }

    /// R6: while one launcher's game runs, a second launcher on the same data folder fails before
    /// it backs up, writes the ini or prepares.
    func testSecondLauncherStopsBeforeTouchingTheIni() async throws {
        let fake = try fakeGame("while [[ ! -f \"$(dirname \"$0\")/stop\" ]]; do sleep 0.05; done; exit 0")
        let first = Launcher(dirs: fake.dirs, runtime: fake.runtime, pipeline: FakePipeline())
        let running = LockedBox(false)
        let task = Task {
            try await first.launch(game: fake.game, profile: .vanilla, settings: LauncherSettings()) { phase in
                if phase == .running { running.mutate { $0 = true } }
            }
        }
        defer { FileManager.default.createFile(atPath: fake.root.appendingPathComponent("stop").path, contents: nil) }
        for _ in 0..<200 where !running.value { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(running.value)
        let ini = try Data(contentsOf: fake.dirs.iniFile)

        let second = Launcher(dirs: fake.dirs, runtime: fake.runtime, pipeline: FakePipeline())
        let backups = LockedBox(0)
        second.backup = { _ in backups.mutate { $0 += 1 } }
        do {
            _ = try await second.launch(game: fake.game, profile: .max, settings: LauncherSettings()) { _ in }
            XCTFail("the second launch started")
        } catch let error as GameProcessError {
            guard case .alreadyRunning = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(backups.value, 0)
        XCTAssertEqual(try Data(contentsOf: fake.dirs.iniFile), ini)

        FileManager.default.createFile(atPath: fake.root.appendingPathComponent("stop").path, contents: nil)
        let result = try await task.value
        XCTAssertEqual(result.outcome, .finished)
        // The lock is free again after the launch.
        _ = try await second.launch(game: fake.game, profile: .max, settings: LauncherSettings()) { _ in }
        XCTAssertEqual(try IniFile.load(fake.dirs.iniFile)["upscaler"], "metalfx")
    }

    /// R11: cancelling the launch while a pipeline step runs ends the step and the launch
    /// (outcome .cancelled, no error), and the game is not started.
    func testCancellingDuringPreparationStopsTheLaunch() async throws {
        let fake = try fakeGame("touch \"$(dirname \"$0\")/started\"; exit 0")
        let launcher = Launcher(dirs: fake.dirs, runtime: fake.runtime, pipeline: SlowPipeline())
        let started = Date()
        let task = Task { try await launcher.launch(game: fake.game, profile: .vanilla, settings: LauncherSettings()) { _ in } }
        try await Task.sleep(nanoseconds: 300_000_000)
        launcher.cancel()
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.root.appendingPathComponent("started").path))
    }
}

/// A pipeline whose launch steps take a minute unless their task is cancelled (like a killed
/// prepare.py, the cancelled step fails).
private struct SlowPipeline: Pipeline {
    var fast = FakePipeline()
    func quickCheck(game: URL) async throws -> GameCheck { try await fast.quickCheck(game: game) }
    func thoroughCheck(game: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String] { [] }
    func scaledSizes(settings: URL) async throws -> ScaledSizes? { nil }
    func run(_ step: LaunchSpec.Step, environment: [String: String], log: FileHandle?) async throws {
        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { throw PipelineError("\(step.script) failed (killed)") }
    }
    func buildModOverlay(game: URL, out: URL, modsDir: URL, config: URL) async throws -> URL { game }
}
