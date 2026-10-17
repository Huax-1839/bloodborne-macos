// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class PkgToolTests: ImportTestCase {
    private let ps4Usage = "Usage: ps4-pkg-tool <path/to/pkg> [path/to/output]"

    /// A ps4-pkg-tool that behaves like the real one: <out>/CUSA00000/ with a game tree.
    /// "update" in the PKG's name makes it the update's files.
    private func fakePS4Tool(in folder: URL? = nil) throws -> URL {
        try script("ps4-pkg-tool", in: folder, """
        if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then echo '\(ps4Usage)' >&2; exit 0; fi
        pkg="$1"; out="$2"
        echo 'Title ID: CUSA00000'
        mkdir -p "$out/CUSA00000/sce_sys" "$out/CUSA00000/dvdroot_ps4"
        case "$pkg" in
          *update*) echo upd > "$out/CUSA00000/eboot.bin"; echo upd > "$out/CUSA00000/sce_sys/param.sfo"
                    echo upd > "$out/CUSA00000/dvdroot_ps4/a.dcx"; echo only > "$out/CUSA00000/update-only.txt" ;;
          *)        echo base > "$out/CUSA00000/eboot.bin"; echo base > "$out/CUSA00000/sce_sys/param.sfo"
                    echo base > "$out/CUSA00000/dvdroot_ps4/a.dcx"; echo base > "$out/CUSA00000/dvdroot_ps4/b.dcx" ;;
        esac
        echo 'Extraction complete.'
        """)
    }

    private func pkg(_ name: String) throws -> URL {
        try write(dir, name, String(repeating: "p", count: 4096))
        return dir.appendingPathComponent(name)
    }

    // MARK: - detect

    func testDetectsEachToolByNameInExtraPaths() throws {
        for kind in PkgTool.Kind.allCases {
            let folder = dir.appendingPathComponent("tools-\(kind.rawValue)")
            let tool = try script(kind.executableName, in: folder, "exit 0")
            let found = PkgTool.detect(extraPaths: [folder], environment: [:], systemDirectories: [], applicationsDirectories: [])
            XCTAssertEqual(found, PkgTool(kind: kind, executable: tool))
            XCTAssertEqual(PkgTool.detect(extraPaths: [tool], environment: [:], systemDirectories: [], applicationsDirectories: []),
                           PkgTool(kind: kind, executable: tool))
        }
    }

    func testRecommendedToolComesFirstInAFolder() throws {
        let folder = dir.appendingPathComponent("bin")
        _ = try script("orbis-pkg-util", in: folder, "exit 0")
        _ = try script("pkgextract", in: folder, "exit 0")
        let ps4 = try script("ps4-pkg-tool", in: folder, "exit 0")
        XCTAssertEqual(PkgTool.detect(extraPaths: [], environment: ["PATH": "/nonexistent:" + folder.path],
                                      systemDirectories: [], applicationsDirectories: [])?.executable, ps4)
    }

    func testDetectsInApplicationsSubfoldersBuildAndBin() throws {
        let applications = dir.appendingPathComponent("home/Applications")
        let tool = try script("ps4-pkg-tool", in: applications.appendingPathComponent("ps4-pkg-tools-src/build"), "exit 0")
        XCTAssertEqual(PkgTool.detect(environment: ["PATH": ""], systemDirectories: [], applicationsDirectories: [applications])?.executable.resolvingSymlinksInPath(), tool.resolvingSymlinksInPath())
        let other = dir.appendingPathComponent("home2/Applications")
        let binTool = try script("pkgextract", in: other.appendingPathComponent("pkgextract-1.2/bin"), "exit 0")
        XCTAssertEqual(PkgTool.detect(environment: ["PATH": ""], systemDirectories: [], applicationsDirectories: [other])?.executable.resolvingSymlinksInPath(), binTool.resolvingSymlinksInPath())
        let top = dir.appendingPathComponent("home3/Applications")
        let topTool = try script("orbis-pkg-util", in: top, "exit 0")
        XCTAssertEqual(PkgTool.detect(environment: ["PATH": ""], systemDirectories: [], applicationsDirectories: [top])?.executable.resolvingSymlinksInPath(), topTool.resolvingSymlinksInPath())
    }

    func testDetectUsesHomeApplicationsFromTheEnvironment() throws {
        let home = dir.appendingPathComponent("home")
        let tool = try script("ps4-pkg-tool", in: home.appendingPathComponent("Applications/x/bin"), "exit 0")
        XCTAssertEqual(PkgTool.detect(environment: ["PATH": "", "HOME": home.path], systemDirectories: [])?.executable.resolvingSymlinksInPath(), tool.resolvingSymlinksInPath())
    }

    func testDetectIgnoresNonExecutablesAndUnknownNames() throws {
        let bin = try folder("bin")
        try write(bin, "ps4-pkg-tool", "#!/bin/bash")  // no executable bit
        _ = try script("PkgTool.Core", in: bin, "exit 0")
        _ = try script("something", in: bin, "exit 0")
        XCTAssertNil(PkgTool.detect(extraPaths: [bin], environment: [:], systemDirectories: [], applicationsDirectories: []))
    }

    // MARK: - validate

    func testValidateIdentifiesByUsage() throws {
        let tool = try fakePS4Tool()
        XCTAssertEqual(try PkgTool.validate(tool).get(), PkgTool(kind: .ps4PkgTools, executable: tool))
        let util = try script("orbis-pkg-util", in: try folder("u"), "echo 'orbis-pkg-util 1.0: extract <pkg>' >&2")
        XCTAssertEqual(try PkgTool.validate(util).get().kind, .orbisPkgUtil)
        let extract = try script("pkgextract", in: try folder("e"), "[ \"$1\" = -h ] && echo 'Usage: pkgextract <file.pkg> [-o DIR] [-f]'")
        XCTAssertEqual(try PkgTool.validate(extract).get().kind, .pkgextract)  // answers -h only
    }

    func testValidateIdentifiesARenamedTool() throws {
        let renamed = try script("my-extractor", in: try folder("r"), "echo '\(ps4Usage)' >&2")
        XCTAssertEqual(try PkgTool.validate(renamed).get(), PkgTool(kind: .ps4PkgTools, executable: renamed))
    }

    func testValidateRefusesLibOrbisPkg() throws {
        for name in ["PkgTool.Core", "PkgTool", "PkgTool.Core.dll", "dotnet"] {
            let tool = try script(name, in: try folder("lib-" + name), "echo 'PkgTool.Core usage'")
            XCTAssertEqual(PkgTool.validate(tool), .failure(.libOrbisPkg), name)
        }
        let byUsage = try script("renamed", in: try folder("lib-usage"), "echo 'LibOrbisPkg PkgTool'")
        XCTAssertEqual(PkgTool.validate(byUsage), .failure(.libOrbisPkg))
        XCTAssertNotNil(PkgToolError.libOrbisPkg.errorDescription)
    }

    func testValidateRefusesWrongFiles() throws {
        let bin = try folder("v")
        try write(bin, "pkgextract", "#!/bin/bash\n")
        XCTAssertEqual(PkgTool.validate(bin.appendingPathComponent("pkgextract")), .failure(.notExecutable(bin.appendingPathComponent("pkgextract"))))
        XCTAssertEqual(PkgTool.validate(bin.appendingPathComponent("missing")), .failure(.notFound(bin.appendingPathComponent("missing"))))
        let liar = try script("pkgextract", in: try folder("liar"), "echo 'Usage: grep PATTERN'")
        XCTAssertEqual(PkgTool.validate(liar), .failure(.unrecognized("pkgextract")))
    }

    func testValidateTimesOutAfterFiveSeconds() throws {
        let hang = try script("pkgextract", in: try folder("hang"), "exec sleep 60")
        let started = Date()
        XCTAssertEqual(PkgTool.validate(hang), .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    // MARK: - extract

    func testExtractPS4PkgToolLocatesTheTitleFolder() async throws {
        let tool = PkgTool(kind: .ps4PkgTools, executable: try fakePS4Tool())
        let output = dir.appendingPathComponent("out/base")
        let fractions = LockedBox<[Double]>([])
        let app = try await tool.extract(pkg: try pkg("base.pkg"), into: output) { value in fractions.mutate { $0.append(value) } }
        XCTAssertEqual(app.lastPathComponent, "CUSA00000")
        XCTAssertEqual(app.deletingLastPathComponent().standardizedFileURL.path, output.standardizedFileURL.path)
        XCTAssertEqual(read(app, "eboot.bin"), "base\n")
        XCTAssertEqual(fractions.value.last, 1)
    }

    func testExtractPassesTheRightArgumentsPerKind() async throws {
        let record = dir.appendingPathComponent("args.txt")
        let body = "printf '%s\\n' \"$@\" > '\(record.path)'\n" + """
        out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
        echo x > "$out/eboot.bin"; mkdir -p "$out/sce_sys"; echo x > "$out/sce_sys/param.sfo"
        """
        let tool = try script("pkgextract", in: try folder("pe"), body)
        let source = try pkg("g.pkg")
        let output = dir.appendingPathComponent("o1")
        let app = try await PkgTool(kind: .pkgextract, executable: tool).extract(pkg: source, into: output) { _ in }
        XCTAssertEqual(app.standardizedFileURL.path, output.standardizedFileURL.path)  // game files directly in the output
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), "\(source.path)\n-o\n\(output.path)\n-f\n")

        let util = try script("orbis-pkg-util", in: try folder("ou"), body)
        let output2 = dir.appendingPathComponent("o2")
        _ = try await PkgTool(kind: .orbisPkgUtil, executable: util).extract(pkg: source, into: output2) { _ in }
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), "extract\n\(source.path)\n-o\n\(output2.path)\n-f\n-q\n")
    }

    func testExtractFailureDeletesTheOutputAndKeepsStderr() async throws {
        let tool = try script("ps4-pkg-tool", in: try folder("fail"), """
        mkdir -p "$2/CUSA00000"
        echo 'Failed to open PKG: nope' >&2
        exit 1
        """)
        let output = dir.appendingPathComponent("out")
        do {
            _ = try await PkgTool(kind: .ps4PkgTools, executable: tool).extract(pkg: try pkg("x.pkg"), into: output) { _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            guard case .extractionFailed(let name, let details) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "ps4-pkg-tools")
            XCTAssertTrue(details.contains("Failed to open PKG: nope"), details)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExtractWithoutAGameInItFails() async throws {
        let tool = try script("ps4-pkg-tool", in: try folder("empty"), "mkdir -p \"$2/CUSA00000\"; exit 0")
        let output = dir.appendingPathComponent("out")
        do {
            _ = try await PkgTool(kind: .ps4PkgTools, executable: tool).extract(pkg: try pkg("x.pkg"), into: output) { _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .nothingExtracted(output))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExtractRefusesANonEmptyOutput() async throws {
        let output = try folder("busy")
        try write(output, "keep.txt", "mine")
        do {
            _ = try await PkgTool(kind: .ps4PkgTools, executable: try fakePS4Tool()).extract(pkg: try pkg("x.pkg"), into: output) { _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            XCTAssertEqual(error, .destinationExists(output))
        }
        XCTAssertEqual(read(output, "keep.txt"), "mine")
    }

    func testCancelledExtractionKillsTheToolAndDeletesTheOutput() async throws {
        let tool = try script("ps4-pkg-tool", in: try folder("slow"), "mkdir -p \"$2/CUSA00000\"; exec sleep 60")
        let output = dir.appendingPathComponent("out")
        let source = try pkg("x.pkg")
        let task = Task { try await PkgTool(kind: .ps4PkgTools, executable: tool).extract(pkg: source, into: output) { _ in } }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let started = Date()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExtractReportsProgressByBytesWritten() async throws {
        let tool = try script("ps4-pkg-tool", in: try folder("grow"), """
        mkdir -p "$2/CUSA00000/sce_sys"; echo x > "$2/CUSA00000/eboot.bin"; echo x > "$2/CUSA00000/sce_sys/param.sfo"
        head -c 2048 /dev/zero > "$2/CUSA00000/half.bin"
        sleep 1.5
        """)
        let fractions = LockedBox<[Double]>([])
        _ = try await PkgTool(kind: .ps4PkgTools, executable: tool).extract(pkg: try pkg("x.pkg"), into: dir.appendingPathComponent("out")) { value in
            fractions.mutate { $0.append(value) }
        }
        // 2 KB + two tiny files of a 4 KB PKG: about half, polled before the tool ended.
        XCTAssertTrue(fractions.value.contains { $0 > 0.4 && $0 < 0.6 }, "\(fractions.value)")
        XCTAssertEqual(fractions.value.last, 1)
    }

    // MARK: - importPKGs

    private func dirs() -> DataDirs { DataDirs(root: dir.appendingPathComponent("data")) }

    func testImportPKGsExtractsMergesAndCleansUp() async throws {
        let tool = PkgTool(kind: .ps4PkgTools, executable: try fakePS4Tool())
        let phases = LockedBox<[GameImporter.Phase]>([])
        let checked = LockedBox<[URL]>([])
        var pipeline = FakePipeline()
        pipeline.check = { url in
            checked.mutate { $0.append(url) }
            return GameCheck(problem: nil, title: "CUSA00000", version: "01.09", imageSHA256: "abc")
        }
        let dirs = dirs()
        let imported = try await GameImporter.importPKGs(base: try pkg("base.pkg"), update: try pkg("update.pkg"), tool: tool,
                                                         dirs: dirs, pipeline: pipeline) { phase, _ in
            phases.mutate { if $0.last != phase { $0.append(phase) } }
        }
        XCTAssertEqual(imported.folder.lastPathComponent, "CUSA00000-1.09")
        XCTAssertEqual(imported.folder.deletingLastPathComponent().standardizedFileURL.path, dirs.gamesDir.standardizedFileURL.path)
        XCTAssertEqual(read(imported.folder, "eboot.bin"), "upd\n")
        XCTAssertEqual(read(imported.folder, "dvdroot_ps4/b.dcx"), "base\n")
        XCTAssertEqual(read(imported.folder, "update-only.txt"), "only\n")
        XCTAssertTrue(imported.check.ok)
        XCTAssertEqual(phases.value, [.extractingBase, .extractingUpdate, .merging, .checking])
        XCTAssertEqual(checked.value.last, imported.folder)
        // Only the merged folder is left in the games folder.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirs.gamesDir.path), ["CUSA00000-1.09"])

        // The same import again gets another name.
        let again = try await GameImporter.importPKGs(base: try pkg("base.pkg"), update: try pkg("update.pkg"), tool: tool,
                                                      dirs: dirs, pipeline: pipeline) { _, _ in }
        XCTAssertEqual(again.folder.lastPathComponent, "CUSA00000-1.09-2")
    }

    func testImportPKGsWithoutUpdateMovesTheBase() async throws {
        let tool = PkgTool(kind: .ps4PkgTools, executable: try fakePS4Tool())
        let imported = try await GameImporter.importPKGs(base: try pkg("base.pkg"), update: nil, tool: tool, dirs: dirs(),
                                                         pipeline: FakePipeline()) { _, _ in }
        XCTAssertEqual(read(imported.folder, "eboot.bin"), "base\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirs().gamesDir.path).count, 1)
    }

    func testImportPKGsWithoutUpdateIsNamedAfterItsVersion() async throws {
        let tool = PkgTool(kind: .ps4PkgTools, executable: try fakePS4Tool())
        var pipeline = FakePipeline()
        pipeline.check = { _ in GameCheck(problem: .missingUpdate, title: "CUSA00000", version: "01.00", imageSHA256: nil) }
        let imported = try await GameImporter.importPKGs(base: try pkg("base.pkg"), update: nil, tool: tool, dirs: dirs(),
                                                         pipeline: pipeline) { _, _ in }
        XCTAssertEqual(imported.folder.lastPathComponent, "CUSA00000-1.00")
        XCTAssertEqual(imported.check.problem, .missingUpdate)
    }

    func testImportPKGsLeavesNothingWhenTheCheckFails() async throws {
        let tool = PkgTool(kind: .ps4PkgTools, executable: try fakePS4Tool())
        let dirs = dirs()
        var pipeline = FakePipeline()
        pipeline.checkFails = { _ in true }
        for update in [nil, try pkg("update.pkg")] {
            do {
                _ = try await GameImporter.importPKGs(base: try pkg("base.pkg"), update: update, tool: tool, dirs: dirs,
                                                      pipeline: pipeline) { _, _ in }
                XCTFail("expected an error")
            } catch is PipelineError {}
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirs.gamesDir.path), [])
        }
    }

    func testImportPKGsChecksSpaceFirstAndCleansUpAfterAFailure() async throws {
        let tool = PkgTool(kind: .ps4PkgTools, executable: try fakePS4Tool())
        let dirs = dirs()
        do {
            _ = try await GameImporter.importPKGs(base: try pkg("base.pkg"), update: try pkg("update.pkg"), tool: tool, dirs: dirs,
                                                  pipeline: FakePipeline(), availableCapacity: 100) { _, _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            guard case .notEnoughSpace(let needed, 100) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(needed, 2 * 4096 + GameImporter.importMargin)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirs.gamesDir.path), [])

        let failing = try script("ps4-pkg-tool", in: try folder("failing"), "mkdir -p \"$2/X\"; echo broken >&2; exit 3")
        do {
            _ = try await GameImporter.importPKGs(base: try pkg("base.pkg"), update: nil, tool: PkgTool(kind: .ps4PkgTools, executable: failing),
                                                  dirs: dirs, pipeline: FakePipeline()) { _, _ in }
            XCTFail("expected an error")
        } catch is ImportError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dirs.gamesDir.path), [])
    }
}
