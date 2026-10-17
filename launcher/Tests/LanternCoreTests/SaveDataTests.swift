// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class SaveDataTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("savedata-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    // MARK: Synthetic saves

    struct Slot {
        var slot: Int
        var name: String
        var level = 10
        var playtime = 3600
        var echoes = 1234
        /// The byte the slot file is filled with (not zero: the slot is occupied).
        var fill: UInt8 = 0xAB
    }

    func put32(_ data: inout Data, _ offset: Int, _ value: Int) {
        for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    /// A save as the game writes it: ten slots, userdata0010 with records, backup files for used
    /// files, sce_sys and, when asked, the .memory folder.
    @discardableResult
    func makeSave(_ userRoot: URL, uid: String = "1", title: String = "CUSA00207", slots: [Slot],
                  memory: Bool = false, marker: UInt8 = 0x11) throws -> SaveLocation {
        let location = SaveLocation(userRoot: userRoot, userID: uid, titleID: title)
        try fm.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let sys = location.titleFolder.appendingPathComponent("SPRJ0005.sce_sys")
        try fm.createDirectory(at: sys, withIntermediateDirectories: true)
        try Data(repeating: marker, count: 1328).write(to: sys.appendingPathComponent("param.bin"))
        try Data("png".utf8).write(to: sys.appendingPathComponent("icon0.png"))
        var global = Data(repeating: marker, count: SaveFormat.globalSize)
        for index in 0..<SaveFormat.slotCount {
            let range = SaveFormat.recordRange(index)
            global.replaceSubrange(range, with: Data(count: SaveFormat.recordSize))
            try Data(count: SaveFormat.slotSize).write(to: location.slotFile(index))
        }
        for slot in slots {
            var record = Data(count: SaveFormat.recordSize)
            put32(&record, 0, 1)
            let units = Array(slot.name.utf16)
            for (i, unit) in units.enumerated() {
                record[10 + i * 2] = UInt8(unit & 0xFF)
                record[11 + i * 2] = UInt8(unit >> 8)
            }
            put32(&record, 44, slot.level)
            put32(&record, 48, slot.playtime)
            put32(&record, 52, slot.echoes)
            record[200] = UInt8(slot.slot) // something of the not decoded part
            global.replaceSubrange(SaveFormat.recordRange(slot.slot), with: record)
            let data = Data(repeating: slot.fill, count: SaveFormat.slotSize)
            try data.write(to: location.slotFile(slot.slot))
            try data.write(to: location.directory.appendingPathComponent(SaveFormat.backupName(slot.slot)))
        }
        try global.write(to: location.globalFile)
        if memory {
            try fm.createDirectory(at: location.memoryFolder, withIntermediateDirectories: true)
            try Data("memory".utf8).write(to: location.memoryFolder.appendingPathComponent("memory.dat"))
        }
        return location
    }

    func store(_ name: String = "backups") -> BackupStore { BackupStore(dir: root.appendingPathComponent(name)) }
    func user(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    // MARK: Characters

    func testParsesCharacters() throws {
        let location = try makeSave(user("a"), slots: [
            Slot(slot: 0, name: "Ömer", level: 42, playtime: 7261, echoes: 99),
            Slot(slot: 4, name: "iop", level: 10),
        ])
        let characters = location.characters()
        XCTAssertEqual(characters.map(\.slot), [0, 4])
        XCTAssertEqual(characters[0], .init(slot: 0, name: "Ömer", level: 42, playtime: 7261, echoes: 99))
        XCTAssertEqual(characters[1].name, "iop")
    }

    func testCharactersAreCrossChecked() throws {
        let location = try makeSave(user("a"), slots: [Slot(slot: 1, name: "Real")])
        // Record present, slot file zero: a leftover summary.
        var global = try Data(contentsOf: location.globalFile)
        var record = global.subdata(in: SaveFormat.recordRange(1))
        record[10] = UInt8(ascii: "G")
        global.replaceSubrange(SaveFormat.recordRange(2), with: record)
        try global.write(to: location.globalFile)
        // Slot file with data, no record.
        try Data(repeating: 1, count: SaveFormat.slotSize).write(to: location.slotFile(3))
        XCTAssertEqual(location.characters().map(\.slot), [1])
    }

    func testNoGlobalFileMeansNoCharacters() throws {
        let location = try makeSave(user("a"), slots: [Slot(slot: 0, name: "X")])
        try fm.removeItem(at: location.globalFile)
        XCTAssertEqual(location.characters(), [])
    }

    func testFindLocations() throws {
        try makeSave(user("a"), uid: "1", title: "CUSA03173", slots: [])
        try makeSave(user("a"), uid: "2", title: "CUSA00207", slots: [])
        XCTAssertEqual(SaveRoot.find(userRoot: user("a")).map { "\($0.userID)/\($0.titleID)" }, ["1/CUSA03173", "2/CUSA00207"])
        XCTAssertEqual(SaveRoot.find(userRoot: user("none")), [])
    }

    // MARK: Whole saves

    func testWholeSaveRoundTripIntoEmptyRoot() throws {
        let source = try makeSave(user("a"), slots: [Slot(slot: 0, name: "Ömer"), Slot(slot: 2, name: "Eileen")], memory: true)
        let archive = root.appendingPathComponent("save.lanternsave")
        let manifest = try SaveArchive.exportSave(source, to: archive, appVersion: "1.2.3")
        XCTAssertEqual(manifest.kind, .save)
        XCTAssertEqual(try SaveArchive.readManifest(archive), manifest)
        XCTAssertEqual(manifest.characters?.map(\.name), ["Ömer", "Eileen"])
        XCTAssertEqual(manifest.appVersion, "1.2.3")

        let result = try SaveArchive.importSave(archive, userRoot: user("b"), backups: store())
        XCTAssertNil(result.backup)
        XCTAssertEqual(result.location.userID, "1")
        XCTAssertEqual(result.location.titleID, "CUSA00207")
        XCTAssertEqual(result.location.characters(), source.characters())
        for name in [SaveFormat.globalName, SaveFormat.slotName(0), SaveFormat.backupName(2)] {
            XCTAssertEqual(try Data(contentsOf: result.location.directory.appendingPathComponent(name)),
                           try Data(contentsOf: source.directory.appendingPathComponent(name)))
        }
        XCTAssertTrue(fm.fileExists(atPath: result.location.titleFolder.appendingPathComponent("SPRJ0005.sce_sys/param.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: result.location.memoryFolder.appendingPathComponent("memory.dat").path))
        // The staging folder is gone.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: user("b").path).sorted(), ["savedata"])
    }

    func testWholeSaveImportReplacesAndBacksUpFirst() throws {
        let source = try makeSave(user("a"), title: "CUSA00207", slots: [Slot(slot: 0, name: "New", fill: 0x77)])
        let archive = root.appendingPathComponent("save.lanternsave")
        try SaveArchive.exportSave(source, to: archive, appVersion: "dev")

        // The target uses another Bloodborne title id, user 5, and has its own character.
        let target = try makeSave(user("b"), uid: "5", title: "CUSA03173", slots: [Slot(slot: 1, name: "Old", fill: 0x55)],
                                  memory: true, marker: 0x22)
        let backups = store()
        let result = try SaveArchive.importSave(archive, userRoot: user("b"), backups: backups)
        XCTAssertEqual(result.location, target)
        XCTAssertEqual(target.characters().map(\.name), ["New"])
        XCTAssertEqual(try Data(contentsOf: target.slotFile(0)), Data(repeating: 0x77, count: SaveFormat.slotSize))
        XCTAssertFalse(fm.fileExists(atPath: target.directory.appendingPathComponent(SaveFormat.backupName(1)).path))
        // Nothing was written under the archive's title id.
        XCTAssertEqual(SaveRoot.find(userRoot: user("b")), [target])
        // The old state is in an automatic backup taken first.
        let backup = try XCTUnwrap(backups.list().first)
        XCTAssertTrue(backup.automatic)
        XCTAssertEqual(try Data(contentsOf: backup.url.appendingPathComponent("savedata/5/CUSA03173/SPRJ0005/userdata0001")),
                       Data(repeating: 0x55, count: SaveFormat.slotSize))
        XCTAssertEqual(result.backup?.url.resolvingSymlinksInPath(), backup.url.resolvingSymlinksInPath())
        // The archive had no memory folder: the target's stays.
        XCTAssertTrue(fm.fileExists(atPath: target.memoryFolder.path))
    }

    func testPreferredTitleSelectsAmongSeveral() throws {
        let archive = root.appendingPathComponent("save.lanternsave")
        try SaveArchive.exportSave(try makeSave(user("a"), slots: [Slot(slot: 0, name: "N")]), to: archive, appVersion: "dev")
        try makeSave(user("b"), title: "CUSA00207", slots: [])
        let wanted = try makeSave(user("b"), title: "CUSA03173", slots: [])
        let result = try SaveArchive.importSave(archive, userRoot: user("b"), backups: store(), preferredTitle: "CUSA03173")
        XCTAssertEqual(result.location, wanted)
        XCTAssertEqual(wanted.characters().map(\.name), ["N"])
    }

    func testExportOverwritesExistingFile() throws {
        let source = try makeSave(user("a"), slots: [Slot(slot: 0, name: "N")])
        let archive = root.appendingPathComponent("save.lanternsave")
        try Data("old".utf8).write(to: archive)
        try SaveArchive.exportSave(source, to: archive, appVersion: "dev")
        XCTAssertEqual(try SaveArchive.readManifest(archive).title, "CUSA00207")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { $0.contains("partial") }, [])
    }

    func testExportWithoutSaveFails() {
        let location = SaveLocation(userRoot: user("none"), userID: "1", titleID: "CUSA00207")
        XCTAssertThrowsError(try SaveArchive.exportSave(location, to: root.appendingPathComponent("x.lanternsave"), appVersion: "dev")) {
            XCTAssertEqual($0 as? SaveError, .noSave)
        }
    }

    // MARK: Characters

    func testCharacterExportImportIntoAnotherSlot() throws {
        let source = try makeSave(user("a"), slots: [Slot(slot: 0, name: "Ömer", level: 77, playtime: 500, echoes: 5, fill: 0x31)])
        let archive = root.appendingPathComponent("char.lanternsave")
        let manifest = try SaveArchive.exportCharacter(slot: 0, of: source, to: archive, appVersion: "dev")
        XCTAssertEqual(manifest.kind, .character)
        XCTAssertEqual(manifest.character, .init(slot: 0, name: "Ömer", level: 77, playtime: 500, echoes: 5))

        let target = try makeSave(user("b"), title: "CUSA03173",
                                  slots: [Slot(slot: 1, name: "Keep", fill: 0x41), Slot(slot: 3, name: "Gone", fill: 0x42)], marker: 0x66)
        let globalBefore = try Data(contentsOf: target.globalFile)
        let backups = store()
        let result = try SaveArchive.importCharacter(archive, intoSlot: 3, of: target, backups: backups)

        XCTAssertEqual(try Data(contentsOf: target.slotFile(3)), Data(repeating: 0x31, count: SaveFormat.slotSize))
        XCTAssertEqual(target.characters().map(\.name), ["Keep", "Ömer"])
        XCTAssertEqual(target.record(slot: 3), source.record(slot: 0))
        // Only that record changed in the global file; the other slot and its backup stay.
        var expected = globalBefore
        expected.replaceSubrange(SaveFormat.recordRange(3), with: source.record(slot: 0)!)
        XCTAssertEqual(try Data(contentsOf: target.globalFile), expected)
        XCTAssertEqual(try Data(contentsOf: target.slotFile(1)), Data(repeating: 0x41, count: SaveFormat.slotSize))
        XCTAssertTrue(fm.fileExists(atPath: target.directory.appendingPathComponent("backup0001").path))
        XCTAssertFalse(fm.fileExists(atPath: target.directory.appendingPathComponent("backup0003").path))
        // The previous state is backed up.
        let backup = try XCTUnwrap(result.backup)
        XCTAssertEqual(try Data(contentsOf: backup.url.appendingPathComponent("savedata/1/CUSA03173/SPRJ0005/userdata0003")),
                       Data(repeating: 0x42, count: SaveFormat.slotSize))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: user("b").path).sorted(), ["savedata"])
    }

    func testCharacterImportRefusesSaveWithoutGlobalFile() throws {
        let source = try makeSave(user("a"), slots: [Slot(slot: 0, name: "X")])
        let archive = root.appendingPathComponent("char.lanternsave")
        try SaveArchive.exportCharacter(slot: 0, of: source, to: archive, appVersion: "dev")
        let target = try makeSave(user("b"), slots: [])
        try fm.removeItem(at: target.globalFile)
        let backups = store()
        XCTAssertThrowsError(try SaveArchive.importCharacter(archive, intoSlot: 2, of: target, backups: backups)) {
            XCTAssertEqual($0 as? SaveError, .noGlobalFile)
        }
        XCTAssertTrue(backups.list().isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: target.globalFile.path))
    }

    func testCharacterImportRefusesBadSlotAndEmptySlotExport() throws {
        let source = try makeSave(user("a"), slots: [Slot(slot: 0, name: "X")])
        let archive = root.appendingPathComponent("char.lanternsave")
        try SaveArchive.exportCharacter(slot: 0, of: source, to: archive, appVersion: "dev")
        XCTAssertThrowsError(try SaveArchive.importCharacter(archive, intoSlot: 10, of: source, backups: store())) {
            XCTAssertEqual($0 as? SaveError, .badSlot(10))
        }
        XCTAssertThrowsError(try SaveArchive.exportCharacter(slot: 5, of: source, to: root.appendingPathComponent("e.lanternsave"), appVersion: "dev")) {
            XCTAssertEqual($0 as? SaveError, .emptySlot(5))
        }
    }

    func testKindMismatchIsRefused() throws {
        let source = try makeSave(user("a"), slots: [Slot(slot: 0, name: "X")])
        let whole = root.appendingPathComponent("whole.lanternsave")
        let character = root.appendingPathComponent("char.lanternsave")
        try SaveArchive.exportSave(source, to: whole, appVersion: "dev")
        try SaveArchive.exportCharacter(slot: 0, of: source, to: character, appVersion: "dev")
        XCTAssertThrowsError(try SaveArchive.importSave(character, userRoot: user("b"), backups: store())) {
            XCTAssertEqual($0 as? SaveError, .wrongKind(expected: .save, found: .character))
        }
        XCTAssertThrowsError(try SaveArchive.importCharacter(whole, intoSlot: 0, of: source, backups: store())) {
            XCTAssertEqual($0 as? SaveError, .wrongKind(expected: .character, found: .save))
        }
        XCTAssertFalse(fm.fileExists(atPath: user("b").appendingPathComponent("savedata").path))
    }

    // MARK: Malformed archives

    /// A ZIP of empty entries (names only), written by hand: ditto would not make a "../" name.
    func zipWithNames(_ names: [String]) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) -> Data { u16(v & 0xFFFF) + u16(v >> 16) }
        for name in names {
            let bytes = Data(name.utf8)
            let offset = out.count
            var local = Data()
            local += u32(0x04034b50)
            local += u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            local += u32(0) + u32(0) + u32(0)
            local += u16(bytes.count) + u16(0)
            local += bytes
            out += local
            var entry = Data()
            entry += u32(0x02014b50)
            entry += u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
            entry += u32(0) + u32(0) + u32(0)
            entry += u16(bytes.count) + u16(0) + u16(0) + u16(0) + u16(0)
            entry += u32(0) + u32(offset)
            entry += bytes
            central += entry
        }
        let start = out.count
        out += central
        out += u32(0x06054b50)
        out += u16(0) + u16(0) + u16(names.count) + u16(names.count)
        out += u32(central.count) + u32(start) + u16(0)
        return out
    }

    func testMalformedArchivesAreRefused() throws {
        let backups = store()
        let target = user("t")
        let existing = try makeSave(target, slots: [Slot(slot: 0, name: "Mine", fill: 0x99)])
        func attempt(_ file: URL, _ check: (SaveError) -> Void, line: UInt = #line) {
            XCTAssertThrowsError(try SaveArchive.importSave(file, userRoot: target, backups: backups), line: line) {
                guard let error = $0 as? SaveError else { return XCTFail("\($0)", line: line) }
                check(error)
            }
        }
        // Not a ZIP.
        let junk = root.appendingPathComponent("junk.lanternsave")
        try Data("this is not a zip".utf8).write(to: junk)
        attempt(junk) { if case .notAnArchive = $0 {} else { XCTFail("\($0)") } }
        // A ZIP without a manifest.
        let noManifest = root.appendingPathComponent("nomanifest.lanternsave")
        try zipWithNames(["Folder/readme.txt"]).write(to: noManifest)
        attempt(noManifest) { if case .notAnArchive = $0 {} else { XCTFail("\($0)") } }
        // A path leaving the folder.
        let evil = root.appendingPathComponent("evil.lanternsave")
        try zipWithNames(["Folder/manifest.json", "../../escape.txt"]).write(to: evil)
        attempt(evil) { XCTAssertEqual($0, .unsafeEntry("../../escape.txt")) }
        let absolute = root.appendingPathComponent("absolute.lanternsave")
        try zipWithNames(["Folder/manifest.json", "/etc/escape.txt"]).write(to: absolute)
        attempt(absolute) { XCTAssertEqual($0, .unsafeEntry("/etc/escape.txt")) }
        XCTAssertThrowsError(try SaveArchive.readManifest(evil))

        // A valid archive with a manifest of another game, another format, or a missing layout.
        let source = try makeSave(user("a"), slots: [Slot(slot: 0, name: "X")])
        let good = root.appendingPathComponent("good.lanternsave")
        try SaveArchive.exportSave(source, to: good, appVersion: "dev")
        func tampered(_ name: String, edit: (inout String) -> Void, remove: [String] = []) throws -> URL {
            let work = root.appendingPathComponent("tamper-\(name)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try Tool.run("/usr/bin/ditto", ["-x", "-k", good.path, work.path])
            let folder = work.appendingPathComponent("LanternSave")
            let manifestURL = folder.appendingPathComponent("manifest.json")
            var text = try String(contentsOf: manifestURL, encoding: .utf8)
            edit(&text)
            try text.write(to: manifestURL, atomically: true, encoding: .utf8)
            for path in remove { try fm.removeItem(at: folder.appendingPathComponent(path)) }
            let out = root.appendingPathComponent("\(name).lanternsave")
            try Tool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, out.path])
            return out
        }
        attempt(try tampered("title", edit: { $0 = $0.replacingOccurrences(of: "CUSA00207", with: "CUSA12345") })) {
            XCTAssertEqual($0, .unknownTitle("CUSA12345"))
        }
        attempt(try tampered("format", edit: { $0 = $0.replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 2") })) {
            XCTAssertEqual($0, .unsupportedFormat(2))
        }
        attempt(try tampered("layout", edit: { _ in }, remove: ["CUSA00207/SPRJ0005"])) {
            if case .badLayout = $0 {} else { XCTFail("\($0)") }
        }
        // None of it touched the existing save or left a backup behind.
        XCTAssertEqual(existing.characters().map(\.name), ["Mine"])
        XCTAssertEqual(try Data(contentsOf: existing.slotFile(0)), Data(repeating: 0x99, count: SaveFormat.slotSize))
        XCTAssertTrue(backups.list().isEmpty)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path).sorted(), ["savedata"])
    }

    // MARK: Migration

    func makeCheckout(_ name: String = "checkout") throws -> URL {
        let checkout = user(name)
        try makeSave(checkout.appendingPathComponent("macos/user"), slots: [Slot(slot: 0, name: "iop", level: 10)])
        try Data("effect_dof=0\n".utf8).write(to: checkout.appendingPathComponent("macos/bbport.ini"))
        let cache = checkout.appendingPathComponent("macos/user/cache/CUSA03173-metal")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: cache.appendingPathComponent("shaders.bin"))
        return checkout
    }

    func testMigrationFromCheckout() throws {
        let checkout = try makeCheckout()
        let source = try XCTUnwrap(RepositoryMigration.detect(folder: checkout))
        XCTAssertTrue(source.hasSaves)
        XCTAssertTrue(source.hasCache)
        XCTAssertEqual(source.characters().map(\.name), ["iop"])
        XCTAssertNotNil(source.ini)

        let dirs = DataDirs(root: user("data"))
        try dirs.create()
        // The data folder already holds a save and a bbport.ini: they are backed up / kept aside.
        try makeSave(dirs.userDir, slots: [Slot(slot: 5, name: "Existing", fill: 0x33)])
        try Data("effect_dof=1\n".utf8).write(to: dirs.iniFile)
        let backups = BackupStore(dir: dirs.backupsDir.appendingPathComponent("user"))

        let result = try source.migrate(into: dirs, userRoot: dirs.userDir, backups: backups, includeCache: true)
        XCTAssertTrue(result.savesTaken)
        XCTAssertTrue(result.iniTaken)
        XCTAssertEqual(result.cacheFoldersTaken, 1)
        XCTAssertNotNil(result.backup)
        XCTAssertEqual(SaveRoot.find(userRoot: dirs.userDir).flatMap { $0.characters() }.map(\.name), ["iop"])
        XCTAssertEqual(try String(contentsOf: dirs.iniFile, encoding: .utf8), "effect_dof=0\n")
        XCTAssertEqual(try String(contentsOf: dirs.root.appendingPathComponent("bbport.ini.before-migration"), encoding: .utf8), "effect_dof=1\n")
        XCTAssertTrue(fm.fileExists(atPath: dirs.userDir.appendingPathComponent("cache/CUSA03173-metal/shaders.bin").path))
        let backup = try XCTUnwrap(backups.list().first)
        XCTAssertTrue(fm.fileExists(atPath: backup.url.appendingPathComponent("savedata/1/CUSA00207/SPRJ0005/userdata0005").path))
        // The checkout is untouched.
        XCTAssertEqual(source.characters().map(\.name), ["iop"])
        // Nothing else was left in the user root.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dirs.userDir.path).filter { $0.hasPrefix(".") }, [])
    }

    func testMigrationWithoutCacheAndIntoOwnProfileRoot() throws {
        let checkout = try makeCheckout()
        let source = try XCTUnwrap(RepositoryMigration.detect(folder: checkout))
        let dirs = DataDirs(root: user("data"))
        try dirs.create()
        let own = dirs.profileUserDir("p1")
        let result = try source.migrate(into: dirs, userRoot: own, backups: BackupStore(dir: dirs.backupsDir.appendingPathComponent("p1")),
                                        includeCache: false)
        XCTAssertNil(result.backup)
        XCTAssertEqual(result.cacheFoldersTaken, 0)
        XCTAssertEqual(SaveRoot.find(userRoot: own).count, 1)
        XCTAssertFalse(fm.fileExists(atPath: dirs.userDir.appendingPathComponent("cache").path))
    }

    func testDetectAcceptsUserRootAndRejectsEmptyFolders() throws {
        let direct = user("direct")
        try makeSave(direct, slots: [Slot(slot: 0, name: "X")])
        let source = try XCTUnwrap(RepositoryMigration.detect(folder: direct))
        XCTAssertEqual(source.userRoot, direct)
        XCTAssertNil(source.ini)
        XCTAssertNil(RepositoryMigration.detect(folder: user("empty")))
        try fm.createDirectory(at: user("empty/macos/user/savedata"), withIntermediateDirectories: true)
        XCTAssertNil(RepositoryMigration.detect(folder: user("empty")))
    }

    func testMigrationRefusesTheLaunchersOwnFolder() throws {
        let dirs = DataDirs(root: user("data"))
        try dirs.create()
        try makeSave(dirs.userDir, slots: [Slot(slot: 0, name: "X")])
        let source = try XCTUnwrap(RepositoryMigration.detect(folder: dirs.userDir))
        XCTAssertThrowsError(try source.migrate(into: dirs, userRoot: dirs.userDir, backups: store(), includeCache: false)) {
            XCTAssertEqual($0 as? SaveError, .sameFolder)
        }
    }

    // MARK: The real save (LANTERN_REAL_SAVE=<a COPY of macos/user/savedata>)

    func testRealSave() throws {
        guard let path = ProcessInfo.processInfo.environment["LANTERN_REAL_SAVE"], !path.isEmpty else {
            throw XCTSkip("LANTERN_REAL_SAVE (a copy of savedata) is not set")
        }
        let copy = user("real")
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        try BackupStore.cloneTree(URL(fileURLWithPath: path), to: copy.appendingPathComponent("savedata"))
        let locations = SaveRoot.find(userRoot: copy)
        let location = try XCTUnwrap(locations.first)
        let characters = location.characters()
        print("LANTERN_REAL_SAVE: \(location.userID)/\(location.titleID): \(characters)")
        let first = try XCTUnwrap(characters.first)
        XCTAssertEqual(first.slot, 0)
        XCTAssertEqual(first.name, "iop")
        XCTAssertEqual(first.level, 10)
        // The whole save and the character survive an export and an import in a fresh root.
        let archive = root.appendingPathComponent("real.lanternsave")
        try SaveArchive.exportSave(location, to: archive, appVersion: "dev")
        let imported = try SaveArchive.importSave(archive, userRoot: user("real-b"), backups: store())
        XCTAssertEqual(imported.location.characters(), characters)
        let characterArchive = root.appendingPathComponent("real-char.lanternsave")
        try SaveArchive.exportCharacter(slot: 0, of: location, to: characterArchive, appVersion: "dev")
        try SaveArchive.importCharacter(characterArchive, intoSlot: 6, of: imported.location, backups: store())
        XCTAssertEqual(imported.location.characters().map(\.slot), [0, 6])
        XCTAssertEqual(imported.location.characters().last?.name, "iop")
    }
}
