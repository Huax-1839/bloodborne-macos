// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class GameImporterTests: ImportTestCase {
    // MARK: - GameFolder.locate

    func testLocateFolderItself() throws {
        let game = try gameTree("CUSA00000", tag: "a")
        XCTAssertEqual(GameFolder.locate(game), game)
    }

    func testLocateSingleChild() throws {
        let outer = try folder("outer")
        try write(outer, "CUSA00000/eboot.bin")
        try write(outer, "CUSA00000/sce_sys/param.sfo")
        try write(outer, "readme.txt")
        XCTAssertEqual(GameFolder.locate(outer)?.lastPathComponent, "CUSA00000")
    }

    func testLocateNeedsBothFilesAndExactlyOneChild() throws {
        let noSfo = try folder("nosfo")
        try write(noSfo, "eboot.bin")
        XCTAssertNil(GameFolder.locate(noSfo))
        let two = try folder("two")
        for id in ["CUSA00001", "CUSA00002"] {
            try write(two, "\(id)/eboot.bin")
            try write(two, "\(id)/sce_sys/param.sfo")
        }
        XCTAssertNil(GameFolder.locate(two))
        XCTAssertNil(GameFolder.locate(dir.appendingPathComponent("missing")))
    }

    // MARK: - merge

    private func makeBaseAndUpdate() throws -> (URL, URL) {
        let base = try gameTree("base", tag: "base", files: [
            "dvdroot_ps4/a.txt": "base-a", "dvdroot_ps4/b/c.txt": "base-c", "dvdroot_ps4/b/only-base.txt": "base-only",
            "sce_module/m.sprx": "base-module", "dvdroot_ps4/deep/er/x.dcx": "base-x"])
        let update = try gameTree("update", tag: "upd", files: [
            "dvdroot_ps4/b/c.txt": "upd-c", "sce_sys/changeinfo/changeinfo.xml": "upd-change",
            "dvdroot_ps4/new/deeper/n.txt": "upd-new", "sce_discmap_patch.plt": "upd-plt"])
        return (base, update)
    }

    func testMergeUpdateWinsBaseUntouched() async throws {
        let (base, update) = try makeBaseAndUpdate()
        let merged = dir.appendingPathComponent("games/merged")
        let last = LockedBox((0, 0))
        try await GameImporter.merge(base: base, update: update, into: merged) { last.value = ($0, $1) }

        // The update wins, also for eboot.bin and sce_sys.
        XCTAssertEqual(read(merged, "eboot.bin"), "upd-eboot")
        XCTAssertEqual(read(merged, "sce_sys/param.sfo"), "upd-sfo")
        XCTAssertEqual(read(merged, "dvdroot_ps4/b/c.txt"), "upd-c")
        // Update-only files in new and nested folders are added.
        XCTAssertEqual(read(merged, "sce_sys/changeinfo/changeinfo.xml"), "upd-change")
        XCTAssertEqual(read(merged, "dvdroot_ps4/new/deeper/n.txt"), "upd-new")
        XCTAssertEqual(read(merged, "sce_discmap_patch.plt"), "upd-plt")
        // Nothing is deleted.
        XCTAssertEqual(read(merged, "dvdroot_ps4/a.txt"), "base-a")
        XCTAssertEqual(read(merged, "dvdroot_ps4/b/only-base.txt"), "base-only")
        XCTAssertEqual(read(merged, "sce_module/m.sprx"), "base-module")
        XCTAssertEqual(read(merged, "dvdroot_ps4/deep/er/x.dcx"), "base-x")
        // The base is as before, the update too.
        XCTAssertEqual(read(base, "eboot.bin"), "base-eboot")
        XCTAssertEqual(read(base, "sce_sys/param.sfo"), "base-sfo")
        XCTAssertEqual(read(base, "dvdroot_ps4/b/c.txt"), "base-c")
        XCTAssertFalse(exists(base, "sce_sys/changeinfo/changeinfo.xml"))
        XCTAssertFalse(exists(base, "dvdroot_ps4/new"))
        XCTAssertEqual(read(update, "eboot.bin"), "upd-eboot")
        XCTAssertEqual(last.value.0, last.value.1)
        XCTAssertGreaterThan(last.value.1, 0)
    }

    func testWritingTheMergedFileDoesNotChangeTheBase() async throws {
        // Clones are copy-on-write: an in-place write in the merged tree stays in the merged tree.
        let (base, update) = try makeBaseAndUpdate()
        let merged = dir.appendingPathComponent("merged")
        try await GameImporter.merge(base: base, update: update, into: merged) { _, _ in }
        try "changed".write(to: merged.appendingPathComponent("dvdroot_ps4/a.txt"), atomically: false, encoding: .utf8)
        XCTAssertEqual(read(base, "dvdroot_ps4/a.txt"), "base-a")
    }

    func testMergeKeepsSymlinksAsSymlinks() async throws {
        let (base, update) = try makeBaseAndUpdate()
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("link").path, withDestinationPath: "eboot.bin")
        let merged = dir.appendingPathComponent("merged")
        try await GameImporter.merge(base: base, update: update, into: merged) { _, _ in }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: merged.appendingPathComponent("link").path), "eboot.bin")
    }

    func testMergeRefusesExistingDestinationAndNonGames() async throws {
        let (base, update) = try makeBaseAndUpdate()
        let existing = try folder("existing")
        do {
            try await GameImporter.merge(base: base, update: update, into: existing) { _, _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .destinationExists(existing))
        }
        let notGame = try folder("notgame")
        do {
            try await GameImporter.merge(base: notGame, update: update, into: dir.appendingPathComponent("m")) { _, _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .notAGameFolder(notGame))
        }
    }

    func testCancellationInsideTheCopyRemovesThePartialDestination() async throws {
        let (base, update) = try makeBaseAndUpdate()
        let merged = dir.appendingPathComponent("games/merged")
        do {
            try await GameImporter.merge(base: base, update: update, into: merged, availableCapacity: nil,
                                         entryHook: { if $0 == 4 { throw CancellationError() } }) { _, _ in }
            XCTFail("expected a cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.path))
        XCTAssertEqual(read(base, "eboot.bin"), "base-eboot")
    }

    func testCancelledTaskStopsAndLeavesNothing() async throws {
        let (base, update) = try makeBaseAndUpdate()
        let merged = dir.appendingPathComponent("merged")
        let task = Task { try await GameImporter.merge(base: base, update: update, into: merged) { _, _ in } }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.path))
    }

    func testSpaceCheckErrorBeforeAnythingIsWritten() async throws {
        let (base, update) = try makeBaseAndUpdate()
        let merged = dir.appendingPathComponent("games/merged")
        do {
            try await GameImporter.merge(base: base, update: update, into: merged, availableCapacity: 1000,
                                         entryHook: nil) { _, _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            guard case .notEnoughSpace(let needed, let available) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(available, 1000)
            // Same volume: the update's bytes and the margin, not the base's.
            XCTAssertGreaterThanOrEqual(needed, GameImporter.spaceMargin)
            XCTAssertLessThan(needed, GameImporter.spaceMargin + 1000)
            XCTAssertNotNil(error.errorDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.deletingLastPathComponent().path))
    }

    func testSpaceCheckPassesWithEnoughRoom() async throws {
        let (base, update) = try makeBaseAndUpdate()
        let merged = dir.appendingPathComponent("merged")
        try await GameImporter.merge(base: base, update: update, into: merged, availableCapacity: GameImporter.spaceMargin + 1 << 20,
                                     entryHook: nil) { _, _ in }
        XCTAssertTrue(GameFolder.isGame(merged))
    }

    // MARK: - Names

    func testFolderNameFromTitleAndVersion() {
        XCTAssertEqual(GameImporter.folderName(title: "CUSA03173", version: "01.09", fallback: "x"), "CUSA03173-1.09")
        XCTAssertEqual(GameImporter.folderName(title: "CUSA03173", version: "?", fallback: "x"), "CUSA03173-1.09")
        XCTAssertEqual(GameImporter.folderName(title: nil, version: nil, fallback: "CUSA01"), "CUSA01-1.09")
        XCTAssertEqual(GameImporter.folderName(title: "CU SA'1", version: "1.00", fallback: "x"), "CUSA1-1.00")
    }

    func testUniqueFolderCountsUp() throws {
        let games = try folder("games")
        try FileManager.default.createDirectory(at: games.appendingPathComponent("A-1.09"), withIntermediateDirectories: true)
        XCTAssertEqual(GameImporter.uniqueFolder(in: games, name: "A-1.09").lastPathComponent, "A-1.09-2")
        XCTAssertEqual(GameImporter.uniqueFolder(in: games, name: "B-1.09").lastPathComponent, "B-1.09")
    }

    // MARK: - Localisation

    func testGermanStringsAreCompiledIn() throws {
        // Older toolchains (Xcode 26) copy the catalog instead of compiling it; launcher/build.sh
        // compiles it for the app then.
        if Bundle.module.path(forResource: "Localizable", ofType: "xcstrings") != nil {
            throw XCTSkip("this toolchain does not compile String Catalogs (build.sh does)")
        }
        func strings(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                                        forLocalization: language), "no \(language) strings")
            return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        }
        let german = try strings("de")
        XCTAssertEqual(german["Found %@, version %@."], "%@ in Version %@ gefunden.")
        XCTAssertNotNil(german["The folder %@ already exists."])
        XCTAssertNotNil(german["The program did not answer to --help within 5 seconds."])
    }

    func testErrorDescriptionsAreNotEmpty() {
        let errors: [ImportError] = [.notEnoughSpace(needed: 5 << 30, available: 1 << 30), .destinationExists(dir),
                                     .notAGameFolder(dir), .copyFailed(path: "a", reason: "b"),
                                     .extractionFailed(tool: "t", details: ""), .extractionFailed(tool: "t", details: "x"),
                                     .nothingExtracted(dir), .cannotStart(tool: "t", reason: "r")]
        for error in errors { XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)") }
    }
}
