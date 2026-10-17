// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class IniFileTests: XCTestCase {
    /// A bbport.ini as the game and the launcher leave it: the game's header, menu keys, bindings
    /// with dots, a foreign comment and a foreign key.
    private let realistic = """
    # bbport settings (in-game menu: Insert / L3+R3)
    menu_language=en
    upscaler=fsr3
    preset=2
    sharpness=0.80
    # my own note
    key.w=W
    key.a = A
    pad.a=cross
    pad.l2 = L2

    custom_thing=keep me
    output_res=1920x1080
    live_resolution=auto
    menu_pos=0.1000,0.2000

    """

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IniFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSubscriptTrimsAndLastLineWins() {
        let ini = IniFile(text: "  a = 1 \nb=2\n# c=3\nno equals\na=4\nkey.w=W\n=x\n")
        XCTAssertEqual(ini["a"], "4")
        XCTAssertEqual(ini["b"], "2")
        XCTAssertNil(ini["c"])
        XCTAssertNil(ini["# c"])
        XCTAssertNil(ini["no equals"])
        XCTAssertEqual(ini["key.w"], "W")
        XCTAssertNil(ini["missing"])
        XCTAssertEqual(ini[" b "], "2")
    }

    func testValueMayBeEmptyOrContainEquals() {
        let ini = IniFile(text: "a=\nb=x=y\n")
        XCTAssertEqual(ini["a"], "")
        XCTAssertEqual(ini["b"], "x=y")
    }

    func testForeignLinesAndCommentsSurviveSet() {
        var ini = IniFile(text: realistic)
        ini.set([("preset", "3"), ("show_fps", "1")])
        XCTAssertEqual(ini["preset"], "3")
        let lines = ini.text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("# my own note"))
        XCTAssertTrue(lines.contains("custom_thing=keep me"))
        XCTAssertTrue(lines.contains("key.a = A"), "untouched lines stay verbatim")
        XCTAssertTrue(lines.contains(""), "blank lines stay")
        XCTAssertEqual(lines.firstIndex(of: "preset=3"), 3, "replaced at its own line")
    }

    func testBindingsSurviveSet() {
        var ini = IniFile(text: realistic)
        ini.set([("upscaler", "metalfx"), ("sharpen", "0")])
        XCTAssertEqual(ini["key.w"], "W")
        XCTAssertEqual(ini["key.a"], "A")
        XCTAssertEqual(ini["pad.a"], "cross")
        XCTAssertEqual(ini["pad.l2"], "L2")
        XCTAssertEqual(ini["upscaler"], "metalfx")
    }

    func testSetOnlyChangesWhatItSets() {
        var ini = IniFile(text: realistic)
        ini.set([("preset", "2")])
        let expected = realistic.replacingOccurrences(of: "preset=2", with: "preset=2")
        XCTAssertEqual(ini.text, expected)
        ini.set([("preset", "4")])
        XCTAssertEqual(ini.text, realistic.replacingOccurrences(of: "preset=2", with: "preset=4"))
    }

    func testDuplicatesCollapseAtFirstLine() {
        var ini = IniFile(text: "a=1\nb=2\na=3\nc=4\na=5\n")
        ini.set([("a", "9")])
        XCTAssertEqual(ini.text, "a=9\nb=2\nc=4\n")
        XCTAssertEqual(ini["a"], "9")
    }

    func testDuplicateWithSpacesAroundKeyCollapses() {
        var ini = IniFile(text: "a=1\n  a  = 2\n")
        ini.set([("a", "3")])
        XCTAssertEqual(ini.text, "a=3\n")
    }

    func testNewKeysAppendedInGivenOrder() {
        var ini = IniFile(text: "x=1\n")
        ini.set([("zeta", "1"), ("alpha", "2"), ("x", "5"), ("mid", "3")])
        XCTAssertEqual(ini.text, "x=5\nzeta=1\nalpha=2\nmid=3\n")
    }

    func testSetWithoutTrailingNewline() {
        var ini = IniFile(text: "a=1\nb=2")
        ini.set([("c", "3")])
        XCTAssertEqual(ini.text, "a=1\nb=2\nc=3\n")
    }

    func testEmptyIniGetsHeader() {
        var ini = IniFile()
        XCTAssertEqual(ini.text, "")
        ini.set([("upscaler", "off"), ("preset", "0")])
        XCTAssertEqual(ini.text, "# bbport settings (in-game menu: Insert / L3+R3)\nupscaler=off\npreset=0\n")
    }

    func testSetOfNothingKeepsEmptyIniEmpty() {
        var ini = IniFile()
        ini.set([])
        XCTAssertEqual(ini.text, "")
    }

    func testNonEmptyIniGetsNoHeader() {
        var ini = IniFile(text: "# mine\n")
        ini.set([("a", "1")])
        XCTAssertEqual(ini.text, "# mine\na=1\n")
    }

    func testSetTrimsKeyAndKeepsValueOnOneLine() {
        var ini = IniFile(text: "a=1\n")
        ini.set([(" b ", " 2 "), ("c", "x\ny\r\nz")])
        XCTAssertEqual(ini["b"], "2")
        XCTAssertEqual(ini["c"], "x y  z")
        XCTAssertEqual(ini.text.components(separatedBy: "\n").count, 4)
    }

    func testRemove() {
        var ini = IniFile(text: "a=1\nb=2\na=3\n# a=4\n")
        ini.remove("a")
        XCTAssertEqual(ini.text, "b=2\n# a=4\n")
        XCTAssertNil(ini["a"])
    }

    func testCRLFInput() {
        var ini = IniFile(text: "# c\r\na=1\r\nb = 2 \r\n\r\nkey.w=W\r\n")
        XCTAssertEqual(ini["a"], "1")
        XCTAssertEqual(ini["b"], "2")
        XCTAssertEqual(ini["key.w"], "W")
        ini.set([("a", "7"), ("n", "1")])
        XCTAssertEqual(ini.text, "# c\na=7\nb = 2 \n\nkey.w=W\nn=1\n")
        XCTAssertFalse(ini.text.contains("\r"))
    }

    func testMissingTrailingNewlineAndBlankLines() {
        let ini = IniFile(text: "a=1\n\n\nb=2")
        XCTAssertEqual(ini["b"], "2")
        XCTAssertEqual(ini.text, "a=1\n\n\nb=2\n")
    }

    func testOnlyBlankLineIsNotEmpty() {
        var ini = IniFile(text: "\n")
        ini.set([("a", "1")])
        XCTAssertEqual(ini.text, "\na=1\n", "Save writes the header only when the file had no lines")
    }

    func testRealisticRoundTrip() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("bbport.ini")
        try IniFile(text: realistic).write(to: url)
        let loaded = try IniFile.load(url)
        XCTAssertEqual(loaded.text, realistic)
        XCTAssertEqual(loaded, IniFile(text: realistic))
        XCTAssertEqual(loaded["output_res"], "1920x1080")
        XCTAssertEqual(loaded["menu_pos"], "0.1000,0.2000")
        XCTAssertEqual(loaded["key.a"], "A")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), realistic)
    }

    func testLoadMissingFileIsEmpty() throws {
        let dir = try temporaryDirectory()
        let ini = try IniFile.load(dir.appendingPathComponent("nope.ini"))
        XCTAssertEqual(ini, IniFile())
        XCTAssertEqual(ini.text, "")
    }

    func testLoadOtherErrorsThrow() throws {
        let dir = try temporaryDirectory()
        // A directory is not a readable ini.
        XCTAssertThrowsError(try IniFile.load(dir))
        // Invalid UTF-8 would be corrupted by a rewrite.
        let url = dir.appendingPathComponent("bad.ini")
        try Data([0x61, 0x3D, 0xFF, 0xFE, 0x0A]).write(to: url)
        XCTAssertThrowsError(try IniFile.load(url))
    }

    func testWriteCreatesParentAndLeavesNoTemporary() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("a/b/bbport.ini")
        var ini = IniFile()
        ini.set([("preset", "1")])
        try ini.write(to: url)
        XCTAssertEqual(try IniFile.load(url)["preset"], "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".tmp"))
        // Overwrite an existing file.
        ini.set([("preset", "2")])
        try ini.write(to: url)
        XCTAssertEqual(try IniFile.load(url)["preset"], "2")
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["bbport.ini"])
    }

    func testWriteFailureLeavesOldFileAndNoTemporary() throws {
        let dir = try temporaryDirectory()
        // The target is a directory: rename(2) of a file onto it fails.
        let url = dir.appendingPathComponent("bbport.ini")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var ini = IniFile()
        ini.set([("a", "1")])
        XCTAssertThrowsError(try ini.write(to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".tmp"))
    }
}
