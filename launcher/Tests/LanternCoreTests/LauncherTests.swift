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
}
