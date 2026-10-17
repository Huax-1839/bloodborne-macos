// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class BackupStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func save(_ user: URL, _ text: String) throws {
        let slot = BackupStore.savedata(user).appendingPathComponent("1/CUSA00207/SPRJ0005", isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: slot.appendingPathComponent("userdata0000"))
    }

    func read(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("savedata/1/CUSA00207/SPRJ0005/userdata0000"), encoding: .utf8)
    }

    func testNothingToBackUp() throws {
        let store = BackupStore(dir: root.appendingPathComponent("backups"))
        XCTAssertNil(try store.backUpBeforeLaunch(userRoot: root.appendingPathComponent("user")))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testRotationKeepsTen() throws {
        let user = root.appendingPathComponent("user")
        let store = BackupStore(dir: root.appendingPathComponent("backups"))
        for i in 0..<13 {
            try save(user, "state \(i)")
            try store.backUpBeforeLaunch(userRoot: user, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60))
        }
        let list = store.list()
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(try read(list[0].url), "state 12")
        XCTAssertEqual(try read(list[9].url), "state 3")
    }

    func testSnapshotAndRestore() throws {
        let user = root.appendingPathComponent("user")
        let store = BackupStore(dir: root.appendingPathComponent("backups"))
        try save(user, "before the boss")
        let snapshot = try store.snapshot(userRoot: user, label: "Father Gascoigne")
        try save(user, "after the boss")
        try store.restore(snapshot, userRoot: user)
        XCTAssertEqual(try read(user), "before the boss")
        // The state before the restore was backed up.
        let auto = store.list().filter(\.automatic)
        XCTAssertEqual(auto.count, 1)
        XCTAssertEqual(try read(auto[0].url), "after the boss")
        XCTAssertEqual(store.list().first { !$0.automatic }?.label, "Father Gascoigne")
        // The snapshot is unchanged after the save is written again (clones are copies).
        try save(user, "later")
        XCTAssertEqual(try read(snapshot.url), "before the boss")
    }

    func testRestoringTheOldestOfTenKeepsIt() throws {
        // Dated in the past: the safety backup the restore takes is the newest.
        let user = root.appendingPathComponent("user")
        let store = BackupStore(dir: root.appendingPathComponent("backups"))
        for i in 0..<10 {
            try save(user, "state \(i)")
            try store.backUpBeforeLaunch(userRoot: user, now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60))
        }
        try save(user, "current")
        let oldest = try XCTUnwrap(store.list().last)
        XCTAssertEqual(try read(oldest.url), "state 0")
        try store.restore(oldest, userRoot: user)
        XCTAssertEqual(try read(user), "state 0")
        XCTAssertEqual(try read(oldest.url), "state 0")
        // The state before the restore was backed up too.
        XCTAssertEqual(try read(store.list()[0].url), "current")
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent(".savedata-restore").path))
    }

    func testUnchangedSaveIsNotBackedUpAgain() throws {
        let user = root.appendingPathComponent("user")
        let store = BackupStore(dir: root.appendingPathComponent("backups"))
        try save(user, "state")
        let first = try store.backUpBeforeLaunch(userRoot: user, now: Date(timeIntervalSince1970: 1_800_000_000))
        let second = try store.backUpBeforeLaunch(userRoot: user, now: Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(second?.url.lastPathComponent, first?.url.lastPathComponent)
        // A changed save is backed up again.
        try save(user, "state 2")
        try store.backUpBeforeLaunch(userRoot: user, now: Date(timeIntervalSince1970: 1_800_000_120))
        XCTAssertEqual(store.list().count, 2)
    }
}
