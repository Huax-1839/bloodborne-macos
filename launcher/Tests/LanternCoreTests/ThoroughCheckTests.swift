// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class ThoroughCheckTests: ImportTestCase {
    private func game() throws -> Game {
        let root = try gameTree("game", tag: "g", files: [
            "dvdroot_ps4/a/x.dcx": "xxxx", "dvdroot_ps4/a/b/y.dcx": "yy", "dvdroot_ps4/readme.txt": "not counted",
            "other/z.dcx": "not under dvdroot_ps4"])
        return Game(path: root, check: GameCheck(problem: nil, title: "CUSA00000", version: "01.09", imageSHA256: nil))
    }

    private func roundTrip(_ value: Game.ThoroughCheck) throws -> Game.ThoroughCheck {
        try JSONDecoder.lantern.decode(Game.ThoroughCheck.self, from: JSONEncoder.lantern.encode(value))
    }

    func testFingerprintCountsOnlyDcxUnderTheDataFolder() throws {
        let fingerprint = Game.ThoroughCheck.fingerprint(of: try game().path)
        XCTAssertEqual(fingerprint.fileCount, 2)
        XCTAssertEqual(fingerprint.totalSize, 6)
    }

    func testFingerprintChangesWhenADcxIsTouchedAddedOrRemoved() throws {
        let game = try game()
        let before = Game.ThoroughCheck.fingerprint(of: game.path)
        let x = game.path.appendingPathComponent("dvdroot_ps4/a/x.dcx")

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: x.path)
        let touched = Game.ThoroughCheck.fingerprint(of: game.path)
        XCTAssertNotEqual(touched, before)
        XCTAssertGreaterThan(touched.newestModification, before.newestModification)
        XCTAssertEqual(touched.fileCount, before.fileCount)

        try write(game.path, "dvdroot_ps4/c.dcx", "zzz")
        XCTAssertEqual(Game.ThoroughCheck.fingerprint(of: game.path).fileCount, 3)
        try FileManager.default.removeItem(at: x)
        XCTAssertEqual(Game.ThoroughCheck.fingerprint(of: game.path).fileCount, 2)

        // Other files do not matter.
        let steady = Game.ThoroughCheck.fingerprint(of: game.path)
        try write(game.path, "dvdroot_ps4/readme.txt", "changed and longer")
        XCTAssertEqual(Game.ThoroughCheck.fingerprint(of: game.path), steady)
    }

    func testIsCurrentSurvivesTheJSONRoundTripAndEndsWithAChange() async throws {
        let game = try game()
        var pipeline = FakePipeline()
        pipeline.broken = ["dvdroot_ps4/a/x.dcx"]
        let checked = try await Game.ThoroughCheck.runThorough(game: game, pipeline: pipeline) { _, _ in }
        let thorough = try XCTUnwrap(checked.thorough)
        XCTAssertEqual(thorough.broken, ["dvdroot_ps4/a/x.dcx"])
        XCTAssertEqual(thorough.fileCount, 2)
        XCTAssertEqual(checked.path, game.path)
        XCTAssertTrue(thorough.isCurrent(for: game.path))
        XCTAssertTrue(try roundTrip(thorough).isCurrent(for: game.path))

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: game.path.appendingPathComponent("dvdroot_ps4/a/b/y.dcx").path)
        XCTAssertFalse(thorough.isCurrent(for: game.path))
        XCTAssertFalse(try roundTrip(thorough).isCurrent(for: game.path))
    }
}
