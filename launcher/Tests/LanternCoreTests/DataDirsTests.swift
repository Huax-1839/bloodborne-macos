// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class DataDirsTests: ImportTestCase {
    func testRemoveLeftoversDeletesOnlyScratchFolders() throws {
        let dirs = DataDirs(root: dir.appendingPathComponent("data"))
        let own = dirs.profileUserDir("p1")
        let leftovers = [
            dirs.gamesDir.appendingPathComponent(".import-1234/base/CUSA00000/eboot.bin"),
            dirs.modsDir.appendingPathComponent(".import-5678/mod/file.dcx"),
            dirs.userDir.appendingPathComponent(".save-import-abcd/manifest.json"),
            dirs.userDir.appendingPathComponent(".savedata-restore/1/x"),
            own.appendingPathComponent(".savedata-migrate/1/x"),
            own.appendingPathComponent(".save-import-ef01/userdata"),
            dirs.root.appendingPathComponent(".bbport.ini.migrate"),
        ]
        let kept = [
            dirs.gamesDir.appendingPathComponent("CUSA00000-1.09/eboot.bin"),
            dirs.modsDir.appendingPathComponent("My Mod/file.dcx"),
            dirs.userDir.appendingPathComponent("savedata/1/CUSA00207/SPRJ0005/userdata0000"),
            own.appendingPathComponent("savedata/1/CUSA00207/SPRJ0005/userdata0000"),
            dirs.root.appendingPathComponent("bbport.ini"),
        ]
        for url in leftovers + kept { try write(url.deletingLastPathComponent(), url.lastPathComponent, "x") }

        XCTAssertEqual(dirs.removeLeftovers().count, leftovers.count)
        for url in leftovers { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        for url in kept { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path) }
        // Nothing left: nothing to do, also without the folders.
        XCTAssertEqual(dirs.removeLeftovers(), [])
        XCTAssertEqual(DataDirs(root: dir.appendingPathComponent("missing")).removeLeftovers(), [])
    }

    func testPreparedFolderIsOnlyRemovedWhenNoOtherGameUsesIt() throws {
        let dirs = DataDirs(root: dir.appendingPathComponent("data"))
        var library = GameLibrary(file: dirs.gamesFile)
        let check = GameCheck(problem: nil, title: "CUSA03173", version: "01.09", imageSHA256: "0123456789abcdef")
        let a = Game(path: dir.appendingPathComponent("A"), check: check)
        let b = Game(path: dir.appendingPathComponent("B"), check: check)
        var other = check
        other.imageSHA256 = "fedcba9876543210"
        let c = Game(path: dir.appendingPathComponent("C"), check: other)
        for game in [a, b, c] { try library.add(game) }

        XCTAssertEqual(dirs.preparedFolder(for: check).lastPathComponent, "CUSA03173-0123456789ab")
        XCTAssertNil(library.preparedFolderOnlyFor(a, dirs: dirs))
        XCTAssertEqual(library.preparedFolderOnlyFor(c, dirs: dirs), dirs.preparedFolder(for: other))
        try library.remove(b.id)
        XCTAssertEqual(library.preparedFolderOnlyFor(a, dirs: dirs), dirs.preparedFolder(for: check))
    }
}
