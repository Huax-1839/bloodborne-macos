// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// Temp folders, fake game trees and fake tools shared by the import tests.
class ImportTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ root: URL, _ path: String, _ content: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func folder(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A game tree with eboot.bin and sce_sys/param.sfo whose contents say `tag`, plus `files`.
    @discardableResult
    func gameTree(_ name: String, tag: String, files: [String: String] = [:]) throws -> URL {
        let root = try folder(name)
        try write(root, "eboot.bin", tag + "-eboot")
        try write(root, "sce_sys/param.sfo", tag + "-sfo")
        for (path, content) in files { try write(root, path, content) }
        return root
    }

    func script(_ name: String, in folder: URL? = nil, _ body: String) throws -> URL {
        let directory = folder ?? dir!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

/// A pipeline that answers from a closure and a broken list.
struct FakePipeline: Pipeline {
    var check: @Sendable (URL) -> GameCheck = { _ in GameCheck(problem: nil, title: "CUSA00000", version: "01.09", imageSHA256: nil) }
    var broken: [String] = []

    func quickCheck(game: URL) async throws -> GameCheck { check(game) }
    func thoroughCheck(game: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String] {
        progress(1, 1)
        return broken
    }
    func scaledSizes(settings: URL) async throws -> ScaledSizes? { nil }
    func run(_ step: LaunchSpec.Step, environment: [String: String], log: FileHandle?) async throws {}
    func buildModOverlay(game: URL, out: URL, modsDir: URL, config: URL) async throws -> URL { game }
}
