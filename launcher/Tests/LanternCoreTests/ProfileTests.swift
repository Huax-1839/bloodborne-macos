// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class ProfileTests: XCTestCase {
    func testAirPresetIniKeys() {
        let keys = Dictionary(uniqueKeysWithValues: Profile.air.iniKeys)
        XCTAssertEqual(keys["effect_dynamic_shadows"], "0")
        XCTAssertEqual(keys["effect_motion_blur"], "0")
        XCTAssertEqual(keys["effect_dof"], "0")
        XCTAssertEqual(keys["effect_ssao"], "1")
        XCTAssertEqual(keys["effect_game_aa"], "1")
        XCTAssertEqual(keys["effect_ssr"], "0")
        XCTAssertEqual(keys["model_lod"], "1")
    }

    func testProfileRoundTrip() throws {
        var profile = Profile.air
        profile.builtin = false
        let data = try JSONEncoder.lantern.encode(profile)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"effect_dof\" : false"))
        XCTAssertEqual(try JSONDecoder.lantern.decode(Profile.self, from: data), profile)
    }

    func testProfileStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = ProfileStore(dir: dir)
        let copy = try store.duplicate(.air, name: "Mine")
        XCTAssertFalse(copy.builtin)
        XCTAssertEqual(ProfileStore(dir: dir).profile(copy.id), copy)
        try store.delete(copy.id)
        XCTAssertNil(ProfileStore(dir: dir).profile(copy.id))
    }

    func testExpertVariableNames() {
        for name in ["BB_VBLANK_HZ", "MVK_CONFIG_LOG_LEVEL", "ROSETTA_ADVERTISE_AVX", "BB_X1"] {
            XCTAssertTrue(ExpertVariables.isValidName(name), name)
        }
        for name in ["DYLD_INSERT_LIBRARIES", "PATH", "BB_", "bb_fps", "BB_FPS ", "BB-FPS", "BB_Ä"] {
            XCTAssertFalse(ExpertVariables.isValidName(name), name)
        }
    }

    /// R4: an imported profile keeps neither foreign variables nor the ones that pick the program,
    /// the ini or the save folders.
    func testImportDropsUnsafeVariables() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("shared.json")
        try Data("""
        {"id":"x","name":"Shared","builtin":true,"environment":{"DYLD_INSERT_LIBRARIES":"/tmp/evil.dylib",
         "BB_PROBE":"/bin/sh","BB_CONFIG":"/tmp/x.ini","BB_USER_DIR":"/tmp","BB_GPU_USER_DIR":"/tmp",
         "PATH":"/tmp","BB_VBLANK_HZ":"120"}}
        """.utf8).write(to: file)
        var store = ProfileStore(dir: dir.appendingPathComponent("profiles"))
        let read = try store.readImport(from: file)
        XCTAssertEqual(read.profile.environment, ["BB_VBLANK_HZ": "120"])
        XCTAssertEqual(read.dropped, ["BB_CONFIG", "BB_GPU_USER_DIR", "BB_PROBE", "BB_USER_DIR", "DYLD_INSERT_LIBRARIES", "PATH"])
        XCTAssertFalse(read.profile.builtin)
        XCTAssertNotEqual(read.profile.id, "x")

        let imported = try store.importProfile(from: file)
        XCTAssertEqual(ProfileStore(dir: store.dir).profile(imported.id)?.environment, ["BB_VBLANK_HZ": "120"])
    }
}
