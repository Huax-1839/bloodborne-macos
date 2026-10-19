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

    /// The first edit of a preset: a user copy with the edit, the preset itself unchanged.
    func testUserCopyOfPreset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = ProfileStore(dir: dir)
        var edited = Profile.air
        edited.frameRate = .fps60
        let copy = edited.userCopy(name: store.uniqueName("MacBook Air (customised)"))
        try store.save(copy)
        XCTAssertFalse(copy.builtin)
        XCTAssertNotEqual(copy.id, Profile.air.id)
        XCTAssertEqual(copy.basedOn, Profile.air.id)
        XCTAssertEqual(copy.frameRate, .fps60)
        XCTAssertEqual(store.profile(Profile.air.id), .air)
        XCTAssertEqual(ProfileStore(dir: dir).profile(copy.id), copy)
        // A copy of the copy still points at the preset; a second copy gets its own name.
        let again = copy.userCopy(name: store.uniqueName("MacBook Air (customised)"))
        XCTAssertEqual(again.basedOn, Profile.air.id)
        XCTAssertEqual(again.name, "MacBook Air (customised) 2")
        XCTAssertEqual(store.uniqueName("macbook air"), "macbook air 2")
        XCTAssertEqual(store.uniqueName("Mine"), "Mine")
    }

    /// An edited preset keeps only what changed; the shipped preset stays underneath; reset
    /// removes the adjustment.
    func testPresetAdjustment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = ProfileStore(dir: dir)
        var edited = Profile.air
        edited.frameRate = .fps60
        edited.renderResolution = nil
        edited.name = "Renamed"
        try store.save(edited)
        let file = dir.appendingPathComponent("presets/\(Profile.air.id).json")
        let delta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(delta.keys), ["frameRate", "renderResolution"])
        XCTAssertTrue(delta["renderResolution"] is NSNull)
        XCTAssertEqual(store.adjustments[Profile.air.id], ["frameRate", "renderResolution"])

        // Read back: the adjustment over the shipped values, still the preset, its name kept.
        let reread = ProfileStore(dir: dir)
        let air = try XCTUnwrap(reread.profile(Profile.air.id))
        XCTAssertTrue(air.builtin)
        XCTAssertEqual(air.name, Profile.air.name)
        XCTAssertEqual(air.frameRate, .fps60)
        XCTAssertNil(air.renderResolution)
        XCTAssertEqual(air.modelLOD, Profile.air.modelLOD)
        XCTAssertTrue(reread.isAdjusted(Profile.air.id))
        XCTAssertFalse(reread.isAdjusted(Profile.pro.id))
        XCTAssertEqual(ProfileStore.shipped(Profile.air.id), .air)
        XCTAssertEqual(reread.custom, [])

        // Editing back to the shipped values leaves nothing to keep.
        try store.save(.air)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try store.save(edited)
        try store.reset(Profile.air.id)
        XCTAssertEqual(store.profile(Profile.air.id), .air)
        XCTAssertFalse(store.isAdjusted(Profile.air.id))
    }

    /// An effect switched off and on again is no adjustment, though the preset stores it and the
    /// edit leaves it to the default.
    func testEffectBackToDefaultIsNoAdjustment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = ProfileStore(dir: dir)
        XCTAssertEqual(Profile.air.effects[.ambientOcclusion], true)
        var edited = Profile.air
        edited[effectOn: .ambientOcclusion] = false
        try store.save(edited)
        XCTAssertTrue(store.isAdjusted(Profile.air.id))
        edited[effectOn: .ambientOcclusion] = true
        XCTAssertNil(edited.effects[.ambientOcclusion])
        try store.save(edited)
        XCTAssertFalse(store.isAdjusted(Profile.air.id))
        XCTAssertTrue(try XCTUnwrap(store.profile(Profile.air.id)).isOn(.ambientOcclusion))
    }

    /// An adjustment that cannot be read is kept aside; the shipped preset stands meanwhile.
    func testUnreadablePresetAdjustment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = dir.appendingPathComponent("presets")
        try FileManager.default.createDirectory(at: presets, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: presets.appendingPathComponent("\(Profile.air.id).json"))
        let store = ProfileStore(dir: dir)
        XCTAssertEqual(store.profile(Profile.air.id), .air)
        XCTAssertFalse(store.isAdjusted(Profile.air.id))
        XCTAssertEqual(store.setAside.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: presets.appendingPathComponent("\(Profile.air.id).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.setAside[0].path))
        XCTAssertEqual(store.custom, [])
    }

    /// Lists show each preset with its copies under it, then the other user profiles.
    func testGroupedOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = ProfileStore(dir: dir)
        let own = Profile(id: "own", name: "Aaa own")
        try store.save(own)
        let maxCopy = Profile.max.userCopy(name: "Max (customised)")
        try store.save(maxCopy)
        let airCopy = Profile.air.userCopy(name: "MacBook Air (customised)")
        try store.save(airCopy)
        XCTAssertEqual(store.grouped.map(\.id),
                       [Profile.air.id, airCopy.id, Profile.pro.id, Profile.max.id, maxCopy.id, Profile.vanilla.id, own.id])
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
