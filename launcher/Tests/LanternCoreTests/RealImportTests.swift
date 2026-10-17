// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// Runs the import on the user's real game data (tens of GB, minutes): skipped unless
/// LANTERN_REAL_PKG=1. Environment: LANTERN_REPO (the repository checkout, with game/*.pkg and
/// macos/out), LANTERN_REAL_SCRATCH (the scratch data root, deleted afterwards),
/// LANTERN_REAL_BASE_PKG / LANTERN_REAL_UPDATE_PKG (default: the PKGs in $LANTERN_REPO/game),
/// LANTERN_REAL_BASE_DIR / LANTERN_REAL_UPDATE_DIR (a base folder and an update folder for the
/// merge test, default ~/Games/Bloodborne/CUSA03173 and CUSA03173-patch), LANTERN_REAL_TOOL.
final class RealImportTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var scratch: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["LANTERN_REAL_PKG"] == "1", "set LANTERN_REAL_PKG=1")
        let repo = try XCTUnwrap(environment["LANTERN_REPO"], "LANTERN_REPO")
        let root = try XCTUnwrap(environment["LANTERN_REAL_SCRATCH"], "LANTERN_REAL_SCRATCH")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo))
        scratch = URL(fileURLWithPath: root, isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private var pipeline: PythonPipeline {
        let repo = URL(fileURLWithPath: environment["LANTERN_REPO"]!, isDirectory: true)
        return PythonPipeline(runtime: Runtime(probe: repo.appendingPathComponent("macos/out/bb-probe"), pipeline: repo,
                                               python: URL(fileURLWithPath: "/opt/homebrew/bin/python3"), repository: repo))
    }

    private func games(_ name: String) -> URL {
        URL(fileURLWithPath: environment[name] ?? "", isDirectory: true)
    }

    func testImportRealPKGs() async throws {
        let repo = environment["LANTERN_REPO"]!
        let base = URL(fileURLWithPath: environment["LANTERN_REAL_BASE_PKG"] ?? repo + "/game/Bloodborne.Game.of.the.Year.Edition.PS4-PRELUDE.pkg")
        let update = URL(fileURLWithPath: environment["LANTERN_REAL_UPDATE_PKG"] ?? repo + "/game/Bloodborne.Game.of.the.Year.Edition.Update.v1.09.PS4-PRELUDE.pkg")
        let tool = try XCTUnwrap(environment["LANTERN_REAL_TOOL"].map { try PkgTool.validate(URL(fileURLWithPath: $0)).get() }
                                 ?? PkgTool.detect(), "no PKG tool found")
        print("PKG tool: \(tool.kind) \(tool.executable.lastPathComponent)")
        let dirs = DataDirs(root: scratch)
        let started = Date()
        let times = LockedBox<[(GameImporter.Phase, TimeInterval)]>([])
        let imported = try await GameImporter.importPKGs(base: base, update: update, tool: tool, dirs: dirs, pipeline: pipeline) { phase, fraction in
            times.mutate { if $0.last?.0 != phase { $0.append((phase, Date().timeIntervalSince(started))) } }
            if fraction == 1 { print("  \(phase) done at \(Int(Date().timeIntervalSince(started))) s") }
        }
        let total = Date().timeIntervalSince(started)
        print("importPKGs: \(Int(total)) s, phase starts \(times.value.map { "\($0.0)@\(Int($0.1))s" })")
        print("result: \(imported.folder.lastPathComponent), check \(imported.check)")
        XCTAssertTrue(imported.check.ok, "\(imported.check)")
        XCTAssertEqual(imported.check.version, "01.09")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirs.gamesDir.path), [imported.folder.lastPathComponent])
        let fingerprint = Game.ThoroughCheck.fingerprint(of: imported.folder)
        print("fingerprint: \(fingerprint)")
    }

    func testMergeRealFolders() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Bloodborne")
        let base = environment["LANTERN_REAL_BASE_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("CUSA03173")
        let update = environment["LANTERN_REAL_UPDATE_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("CUSA03173-patch")
        let merged = scratch.appendingPathComponent("games/CUSA03173-1.09")
        let started = Date()
        let last = LockedBox((0, 0))
        try await GameImporter.merge(base: base, update: update, into: merged) { last.value = ($0, $1) }
        print("merge: \(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(last.value.1) entries")
        let check = try await pipeline.quickCheck(game: merged)
        print("check: \(check)")
        XCTAssertTrue(check.ok, "\(check)")
        // The inputs are untouched: the merged tree's eboot.bin is the update's, the base's is not.
        let before = Date()
        let fingerprint = Game.ThoroughCheck.fingerprint(of: merged)
        print("fingerprint \(fingerprint) in \(String(format: "%.2f", Date().timeIntervalSince(before))) s")
        XCTAssertEqual(try Data(contentsOf: merged.appendingPathComponent("eboot.bin")),
                       try Data(contentsOf: update.appendingPathComponent("eboot.bin")))
        XCTAssertNotEqual(try Data(contentsOf: merged.appendingPathComponent("eboot.bin")),
                          try Data(contentsOf: base.appendingPathComponent("eboot.bin")))
    }
}
