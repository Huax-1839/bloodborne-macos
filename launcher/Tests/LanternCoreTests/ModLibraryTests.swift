// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// The mod library against the layouts of tests/test_mods.py and scripts/mods.py's rules.
final class ModLibraryTests: ImportTestCase {
    var modsDir: URL { dir.appendingPathComponent("mods") }
    var library: ModLibrary { ModLibrary(dir: modsDir) }

    /// Makes `<mods>/<path>` (a file with content).
    func file(_ path: String, _ content: String = "mod") throws { try write(modsDir, path, content) }

    func mod(_ name: String) -> Mod? { library.mods().first { $0.name == name } }

    // MARK: Layouts

    func testAcceptedLayouts() throws {
        try file("Plain/dvdroot_ps4/chr/a.dcx")
        try file("App0/app0/dvdroot_ps4/chr/a.dcx")
        try file("Title/CUSA03173/dvdroot_ps4/chr/a.dcx")
        try file("Old/cusa00900/DVDROOT_PS4/chr/a.dcx")
        try file("Archive/Archive v1.2/dvdroot_ps4/chr/a.dcx")
        try file("Archive/readme.txt", "notes")
        try file("Bare/chr/a.dcx")
        try file("Bare/parts/p.dcx")
        try file("Nested/Nested/app0/dvdroot_ps4/chr/a.dcx")
        try file("Upper/DVDROOT_PS4/Chr/A.DCX")
        try file("Junk/stuff/x")
        let mods = library.mods()
        XCTAssertEqual(mods.map(\.name), ["App0", "Archive", "Bare", "Junk", "Nested", "Old", "Plain", "Title", "Upper"])
        XCTAssertEqual(mods.filter { $0.problem == nil }.map(\.name), ["App0", "Archive", "Bare", "Nested", "Old", "Plain", "Title", "Upper"])
        XCTAssertEqual(mod("Plain")?.files, ["dvdroot_ps4/chr/a.dcx"])
        XCTAssertEqual(mod("Plain")?.layout, "dvdroot_ps4")
        XCTAssertEqual(mod("App0")?.layout, "app0/dvdroot_ps4")
        XCTAssertEqual(mod("Title")?.layout, "CUSA03173/dvdroot_ps4")
        XCTAssertEqual(mod("Archive")?.layout, "Archive v1.2/dvdroot_ps4")
        XCTAssertEqual(mod("Nested")?.layout, "Nested/app0/dvdroot_ps4")
        // The bare game folders go under dvdroot_ps4; the readme stays out.
        XCTAssertEqual(mod("Bare")?.files, ["dvdroot_ps4/chr/a.dcx", "dvdroot_ps4/parts/p.dcx"])
        XCTAssertEqual(mod("Archive")?.files, ["dvdroot_ps4/chr/a.dcx"])
        // Other case: the path keeps the mod's spelling, the match key does not.
        XCTAssertEqual(mod("Upper")?.files, ["DVDROOT_PS4/Chr/A.DCX"])
        XCTAssertEqual(ModLibrary.key("DVDROOT_PS4/Chr/A.DCX"), ModLibrary.key("dvdroot_ps4/chr/a.dcx"))
        XCTAssertNotNil(mod("Junk")?.problem)
        XCTAssertTrue(mod("Junk")?.files.isEmpty ?? false)
    }

    func testWrapperWithOtherFilesIsNotAMod() throws {
        // A wrapper folder next to a file that is not metadata is not looked into.
        try file("Wrapped/inner/dvdroot_ps4/chr/a.dcx")
        try file("Wrapped/setup.exe")
        try file("Two/one/dvdroot_ps4/chr/a.dcx")
        try file("Two/two/dvdroot_ps4/chr/a.dcx")
        try file("Mixed/chr/a.dcx")
        try file("Mixed/other_stuff/x")
        XCTAssertNotNil(mod("Wrapped")?.problem)
        XCTAssertNotNil(mod("Two")?.problem)
        XCTAssertNotNil(mod("Mixed")?.problem)
    }

    func testHiddenFolderIsNotListed() throws {
        try file(".hidden/dvdroot_ps4/chr/a.dcx")
        try file("Visible/dvdroot_ps4/chr/a.dcx")
        XCTAssertEqual(library.mods().map(\.name), ["Visible"])
    }

    func testEmptyDvdrootIsAMod() throws {
        try FileManager.default.createDirectory(at: modsDir.appendingPathComponent("Empty/dvdroot_ps4"), withIntermediateDirectories: true)
        XCTAssertNil(mod("Empty")?.problem)
        XCTAssertEqual(mod("Empty")?.files, [])
    }

    func testSystemFilesAreRefused() throws {
        try file("Eboot/dvdroot_ps4/chr/a.dcx")
        try file("Eboot/eboot.bin")
        try file("Module/app0/dvdroot_ps4/chr/a.dcx")
        try file("Module/app0/sce_module/libfoo.prx")
        try file("Sys/dvdroot_ps4/chr/a.dcx")
        try file("Sys/SCE_SYS/param.sfo")
        for name in ["Eboot", "Module", "Sys"] {
            XCTAssertNotNil(mod(name)?.problem, name)
            XCTAssertTrue(mod(name)?.files.isEmpty ?? false, name)
        }
        XCTAssertThrowsError(try library.importFolder(modsDir.appendingPathComponent("Eboot"))) {
            XCTAssertEqual($0 as? ModError, .systemFile("eboot.bin"))
        }
    }

    func testSymlinksAreRefused() throws {
        try file("Link/dvdroot_ps4/chr/a.dcx")
        try FileManager.default.createSymbolicLink(at: modsDir.appendingPathComponent("Link/dvdroot_ps4/escape"),
                                                   withDestinationURL: dir)
        try file("FileLink/dvdroot_ps4/chr/a.dcx")
        try FileManager.default.createSymbolicLink(at: modsDir.appendingPathComponent("FileLink/dvdroot_ps4/chr/b.dcx"),
                                                   withDestinationURL: modsDir.appendingPathComponent("FileLink/dvdroot_ps4/chr/a.dcx"))
        XCTAssertNotNil(mod("Link")?.problem)
        XCTAssertNotNil(mod("FileLink")?.problem)
        XCTAssertThrowsError(try library.importFolder(modsDir.appendingPathComponent("Link"))) {
            XCTAssertEqual($0 as? ModError, .symlink("dvdroot_ps4/escape"))
        }
    }

    // MARK: Import

    func testImportFolderCopiesAndUniquesNames() throws {
        let source = dir.appendingPathComponent("Source/My Mod")
        try write(source, "dvdroot_ps4/chr/a.dcx", "one")
        try write(source, "dvdroot_ps4/msg/b.msgbnd", "two")
        let first = try library.importFolder(source)
        XCTAssertEqual(first.name, "My Mod")
        XCTAssertEqual(first.files, ["dvdroot_ps4/chr/a.dcx", "dvdroot_ps4/msg/b.msgbnd"])
        XCTAssertEqual(read(modsDir, "My Mod/dvdroot_ps4/chr/a.dcx"), "one")
        XCTAssertTrue(exists(source, "dvdroot_ps4/chr/a.dcx"), "the source stays")
        let second = try library.importFolder(source)
        XCTAssertEqual(second.name, "My Mod 2")
        let third = try library.importFolder(source)
        XCTAssertEqual(third.name, "My Mod 3")
        // The name is unique in any case.
        let lower = dir.appendingPathComponent("Other/my mod")
        try write(lower, "chr/a.dcx")
        XCTAssertEqual(try library.importFolder(lower).name, "my mod 4")
        // No temporary folder is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: modsDir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testImportFolderRefusesANonMod() throws {
        let source = dir.appendingPathComponent("Source/Notes")
        try write(source, "readme.txt")
        try write(source, "pics/a.png")
        XCTAssertThrowsError(try library.importFolder(source)) {
            guard case .notAMod(let name, let found) = $0 as? ModError else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "Notes")
            XCTAssertEqual(found, ["pics/", "readme.txt"])
        }
        XCTAssertTrue(library.mods().isEmpty)
    }

    func makeZip(_ name: String, from folder: URL, keepParent: Bool = false) throws -> URL {
        let zip = dir.appendingPathComponent(name)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        return zip
    }

    func testImportArchive() throws {
        let content = dir.appendingPathComponent("Pack")
        try write(content, "dvdroot_ps4/chr/a.dcx", "zipped")
        try write(content, "readme.txt", "hi")
        let zip = try makeZip("Pack v2.zip", from: content)
        let imported = try library.importArchive(zip)
        XCTAssertEqual(imported.name, "Pack v2")
        XCTAssertEqual(imported.files, ["dvdroot_ps4/chr/a.dcx"])
        XCTAssertEqual(read(modsDir, "Pack v2/dvdroot_ps4/chr/a.dcx"), "zipped")
        XCTAssertEqual(try library.importArchive(zip).name, "Pack v2 2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: modsDir.path).filter { $0.hasPrefix(".") }, [])
    }

    func testImportArchiveWithWrapperFolderAndMacOSMetadata() throws {
        let content = dir.appendingPathComponent("Fancy Mod")
        try write(content, "chr/a.dcx", "bare")
        // keepParent: the folder is in the archive; ditto also adds __MACOSX for extended attributes.
        let marked = content.appendingPathComponent("chr/a.dcx")
        _ = marked.withUnsafeFileSystemRepresentation { path in setxattr(path, "com.example.test", "x", 1, 0, 0) }
        let zip = try makeZip("fancy.zip", from: content, keepParent: true)
        let imported = try library.importArchive(zip)
        XCTAssertEqual(imported.name, "fancy")
        XCTAssertNil(imported.problem)
        XCTAssertEqual(imported.files, ["dvdroot_ps4/chr/a.dcx"])
        XCTAssertTrue(imported.layout.hasPrefix("Fancy Mod: "))
        XCTAssertTrue(imported.layout.contains("chr"))
        XCTAssertFalse(exists(modsDir, "fancy/__MACOSX"))
    }

    func testImportArchiveWithoutAModNamesWhatItHolds() throws {
        let content = dir.appendingPathComponent("Docs")
        try write(content, "manual.pdf")
        try write(content, "stuff/x.bin")
        let zip = try makeZip("Docs.zip", from: content)
        XCTAssertThrowsError(try library.importArchive(zip)) {
            guard case .notAMod(let name, let found) = $0 as? ModError else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "Docs.zip")
            XCTAssertEqual(found, ["manual.pdf", "stuff/"])
            XCTAssertTrue(($0 as? ModError)?.errorDescription?.contains("manual.pdf, stuff/") ?? false)
        }
        XCTAssertTrue(library.mods().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: modsDir.path), [])
    }

    func testImportArchiveFormats() throws {
        for ext in ["7z", "rar"] {
            let url = dir.appendingPathComponent("a.\(ext)")
            try Data().write(to: url)
            XCTAssertThrowsError(try library.importArchive(url)) {
                XCTAssertEqual($0 as? ModError, .unsupportedArchive(ext))
                XCTAssertTrue(($0 as? ModError)?.errorDescription?.contains("Unarchiver") ?? false)
            }
        }
        let text = dir.appendingPathComponent("a.txt")
        try Data().write(to: text)
        XCTAssertThrowsError(try library.importArchive(text)) { XCTAssertEqual($0 as? ModError, .notAnArchive("a.txt")) }
        // A damaged ZIP.
        let broken = dir.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: broken)
        XCTAssertThrowsError(try library.importArchive(broken)) {
            guard case .unpackFailed = $0 as? ModError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: modsDir.path)) ?? [], [])
    }

    // MARK: Rename and delete

    func testRename() throws {
        try file("One/dvdroot_ps4/chr/a.dcx")
        try file("Two/dvdroot_ps4/chr/a.dcx")
        let one = try XCTUnwrap(mod("One"))
        XCTAssertEqual(try library.rename(one, to: "  Uno ").name, "Uno")
        XCTAssertEqual(library.mods().map(\.name), ["Two", "Uno"])
        let uno = try XCTUnwrap(mod("Uno"))
        XCTAssertThrowsError(try library.rename(uno, to: "two")) { XCTAssertEqual($0 as? ModError, .nameTaken("two")) }
        for bad in ["", " ", ".x", "a/b", "a:b"] {
            XCTAssertThrowsError(try library.rename(uno, to: bad), bad) { XCTAssertEqual($0 as? ModError, .invalidName(bad)) }
        }
        // Only the case changes.
        XCTAssertEqual(try library.rename(uno, to: "UNO").name, "UNO")
        XCTAssertEqual(library.mods().map(\.name), ["Two", "UNO"])
    }

    func testDeleteMovesToTheTrash() throws {
        try file("Gone/dvdroot_ps4/chr/a.dcx")
        let gone = try XCTUnwrap(mod("Gone"))
        try library.delete(gone)
        XCTAssertTrue(library.mods().isEmpty)
        // Clean up the Trash entry the test made (it is named like the folder, perhaps with a suffix).
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
            for entry in entries where entry.hasPrefix("Gone") && FileManager.default.fileExists(atPath: trash.appendingPathComponent(entry + "/dvdroot_ps4/chr/a.dcx").path) {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(entry))
            }
        }
    }

    // MARK: Conflicts

    func testConflictsOfThreeMods() throws {
        try file("A/dvdroot_ps4/chr/a.dcx")
        try file("A/dvdroot_ps4/chr/only_a.dcx")
        try file("B/dvdroot_ps4/chr/a.dcx")
        try file("B/dvdroot_ps4/msg/m.bnd")
        try file("C/DVDROOT_PS4/CHR/A.DCX")
        try file("C/DVDROOT_PS4/msg/M.BND")
        let a = try XCTUnwrap(mod("A")), b = try XCTUnwrap(mod("B")), c = try XCTUnwrap(mod("C"))
        let conflicts = ModLibrary.conflicts([a, b, c])
        XCTAssertEqual(conflicts.count, 2)
        XCTAssertEqual(conflicts[0].mods, ["A", "B", "C"])
        XCTAssertEqual(conflicts[0].winner, "C")
        XCTAssertEqual(conflicts[0].path, "DVDROOT_PS4/CHR/A.DCX", "the winner's spelling")
        XCTAssertEqual(conflicts[1].mods, ["B", "C"])
        XCTAssertEqual(conflicts[1].winner, "C")
        // The order decides the winner; a mod alone conflicts with nothing.
        XCTAssertEqual(ModLibrary.conflicts([c, b, a]).first?.winner, "A")
        XCTAssertEqual(ModLibrary.conflicts([c, b, a]).first?.mods, ["C", "B", "A"])
        XCTAssertEqual(ModLibrary.conflicts([a]), [])
        XCTAssertEqual(ModLibrary.conflicts([]), [])
        XCTAssertEqual(ModLibrary.conflicts([a, b]).map(\.winner), ["B"])
    }

    // MARK: mods.py

    /// The same trees through scripts/mods.py: the same mods accepted and the same files.
    func testAgreesWithModsPy() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "no python3")
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }
        let script = repo.appendingPathComponent("scripts/mods.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script.path), "no scripts/mods.py")

        try file("Plain/dvdroot_ps4/chr/a.dcx")
        try file("Plain/dvdroot_ps4/Msg/b.bnd")
        try file("App0/app0/dvdroot_ps4/chr/a.dcx")
        try file("Title/CUSA03173/dvdroot_ps4/chr/a.dcx")
        try file("Archive/Archive v1.2/dvdroot_ps4/chr/a.dcx")
        try file("Archive/readme.txt")
        try file("Bare/chr/a.dcx")
        try file("Bare/parts/p.dcx")
        try file("Nested/Nested/app0/dvdroot_ps4/chr/a.dcx")
        try file("Upper/DVDROOT_PS4/Chr/A.DCX")
        try file("Junk/stuff/x")
        try file("Eboot/dvdroot_ps4/chr/a.dcx")
        try file("Eboot/eboot.bin")
        try file("Sys/app0/dvdroot_ps4/chr/a.dcx")
        try file("Sys/app0/sce_sys/param.sfo")
        try file("Link/dvdroot_ps4/chr/a.dcx")
        try FileManager.default.createSymbolicLink(at: modsDir.appendingPathComponent("Link/dvdroot_ps4/l"), withDestinationURL: dir)

        let driver = """
        import importlib.util, json, sys
        from pathlib import Path
        spec = importlib.util.spec_from_file_location('bbmods', sys.argv[1])
        mods = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mods)
        out = {}
        for name in mods.discover(sys.argv[2]):
            try:
                out[name] = sorted(p.as_posix() for p, _ in mods.mod_files(Path(sys.argv[2]) / name))
            except ValueError:
                out[name] = None
        print(json.dumps(out))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-c", driver, script.path, modsDir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        var ours: [String: [String]?] = [:]
        for mod in library.mods() where mod.problem == nil || expected[mod.name] != nil {
            ours[mod.name] = mod.problem == nil ? mod.files.sorted() : .some(nil)
        }
        XCTAssertEqual(Set(ours.keys), Set(expected.keys))
        for (name, value) in expected {
            let theirs = value as? [String]
            XCTAssertEqual(ours[name] ?? nil, theirs, name)
        }
        // Every folder mods.py refuses or does not discover has a problem here.
        for mod in library.mods() where expected[mod.name] == nil || expected[mod.name] is NSNull {
            XCTAssertNotNil(mod.problem, mod.name)
        }
    }
}
