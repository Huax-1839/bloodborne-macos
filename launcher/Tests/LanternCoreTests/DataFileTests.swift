// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// The launcher's JSON files from another version (fields missing) or damaged (R2).
final class DataFileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("datafile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testProfileWithOnlyIdAndName() throws {
        let profile = try JSONDecoder.lantern.decode(Profile.self, from: Data(#"{"id":"x","name":"y"}"#.utf8))
        XCTAssertEqual(profile, Profile(id: "x", name: "y"))
        XCTAssertFalse(profile.ownSaves)
        XCTAssertEqual(profile.frameRate, .fps30)
    }

    func testProfileWithAnUnknownValueKeepsTheDefault() throws {
        let json = #"{"id":"x","name":"y","frameRate":"45","renderer":"vulkan","ownSaves":true,"future":1}"#
        let profile = try JSONDecoder.lantern.decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.frameRate, .fps30)
        XCTAssertEqual(profile.renderer, .vulkan)
        XCTAssertTrue(profile.ownSaves)
    }

    func testProfileStoreKeepsAnUnreadableProfileAside() throws {
        _ = try write("profiles/old.json", #"{"id":"old","name":"Old"}"#)
        _ = try write("profiles/broken.json", "{ not json")
        let store = ProfileStore(dir: dir.appendingPathComponent("profiles"))
        XCTAssertEqual(store.custom.map(\.id), ["old"])
        XCTAssertEqual(store.setAside.count, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("profiles").path)
        XCTAssertTrue(names.contains { $0.hasPrefix("broken.json.unreadable-") })
        XCTAssertFalse(names.contains("broken.json"))
    }

    func testLauncherStateWithMissingFields() throws {
        let url = try write("launcher.json", #"{"activeGame":"g","settings":{"fullscreen":true}}"#)
        var setAside: [URL] = []
        let state = LauncherState.load(url, setAside: &setAside)
        XCTAssertEqual(state.activeGame, "g")
        XCTAssertEqual(state.activeProfile, Profile.air.id)
        XCTAssertTrue(state.settings.fullscreen)
        XCTAssertTrue(state.settings.skipNetworkChoice)
        XCTAssertTrue(setAside.isEmpty)
    }

    func testCorruptLauncherStateIsKeptAside() throws {
        let url = try write("launcher.json", "garbage")
        var setAside: [URL] = []
        let state = LauncherState.load(url, setAside: &setAside)
        XCTAssertEqual(state, LauncherState())
        XCTAssertEqual(setAside.count, 1)
        try state.save(url)
        XCTAssertEqual(try String(contentsOf: setAside[0], encoding: .utf8), "garbage")
        // A missing file is no error.
        var none: [URL] = []
        _ = LauncherState.load(dir.appendingPathComponent("missing.json"), setAside: &none)
        XCTAssertTrue(none.isEmpty)
    }

    private let check = #"{"title":"CUSA03173","version":"01.09","imageSHA256":"abc"}"#

    func testGameWithoutManaged() throws {
        let file = try write("games.json", #"[{"id":"a","path":"file:///Games/A/","check":\#(check),"added":"2026-10-01T10:00:00Z"}]"#)
        let library = GameLibrary(file: file)
        XCTAssertEqual(library.games.map(\.id), ["a"])
        XCTAssertFalse(library.games[0].managed)
        XCTAssertNil(library.setAside)
    }

    func testCorruptGamesFileIsKeptAsideWithTheReadableGames() throws {
        let file = try write("games.json", #"[{"id":"a","path":"file:///Games/A/","check":\#(check)},{"id":"b"}]"#)
        var library = GameLibrary(file: file)
        XCTAssertEqual(library.games.map(\.id), ["a"])
        let aside = try XCTUnwrap(library.setAside)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("games.json.unreadable-"))
        // The next save writes a new games.json; the kept file stays as it was.
        try library.remove("a")
        XCTAssertTrue(try String(contentsOf: aside, encoding: .utf8).contains(#""id":"b""#))
        XCTAssertEqual(try files().count, 2)

        try Data("{".utf8).write(to: file)
        XCTAssertTrue(GameLibrary(file: file).games.isEmpty)
        // Kept aside under a second name, the first one untouched.
        XCTAssertEqual(try files().filter { $0.hasPrefix("games.json.unreadable-") }.count, 2)
        XCTAssertFalse(try files().contains("games.json"))
    }
}
