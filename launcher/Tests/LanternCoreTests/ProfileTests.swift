// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class ProfileTests: XCTestCase {
    func testAirPresetIniKeys() {
        let keys = Dictionary(uniqueKeysWithValues: Profile.air.iniKeys)
        XCTAssertEqual(keys["effect_dynamic_shadows"], "0")
        XCTAssertEqual(keys["effect_motion_blur"], "0")
        XCTAssertEqual(keys["effect_dof"], "0")
        XCTAssertEqual(keys["effect_ssao"], "0")
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
}
