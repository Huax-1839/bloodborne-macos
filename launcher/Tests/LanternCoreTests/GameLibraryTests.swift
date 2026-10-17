// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// games.json updates from background work (R10).
final class GameLibraryTests: XCTestCase {
    /// A thorough check that ends after the game was removed (or its folder registered again as
    /// a new entry) does not bring the old entry back.
    func testUpdateOfARemovedGameKeepsItRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var library = GameLibrary(file: dir.appendingPathComponent("games.json"))
        let check = GameCheck(problem: nil, title: "CUSA03173", version: "01.09", imageSHA256: nil)
        let game = Game(path: dir.appendingPathComponent("game"), check: check)
        try library.add(game)

        var checked = game
        checked.thorough = Game.ThoroughCheck(fileCount: 1, totalSize: 1, newestModification: Date(), broken: [], date: Date())
        try library.update(checked)
        XCTAssertNotNil(library.game(game.id)?.thorough)

        try library.remove(game.id)
        try library.update(checked)
        XCTAssertTrue(library.games.isEmpty)
        XCTAssertTrue(GameLibrary(file: library.file).games.isEmpty)

        let again = Game(path: game.path, check: check)
        try library.add(again)
        try library.update(checked)
        XCTAssertEqual(library.games.map(\.id), [again.id])
        XCTAssertNil(library.games[0].thorough)
    }
}
