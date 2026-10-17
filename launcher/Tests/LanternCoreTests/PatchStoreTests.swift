// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// PatchStore (L3.5): the built-in and external patch lists, the profile's choices, patches.json
/// and BB_PATCHES, against scripts/patches.py and macos/run.sh.
final class PatchStoreTests: XCTestCase {
    static let repo = LaunchSpecTests.repo
    static let builtInXML = repo.appendingPathComponent("patches/Bloodborne.xml")
    static let env = ["HOME": NSHomeDirectory(), "PATH": LaunchSpecTests.path]

    private var root: URL!
    private var dirs: DataDirs!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-patches-" + UUID().uuidString)
        dirs = DataDirs(root: root)
        try FileManager.default.createDirectory(at: dirs.patchesDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A shadPS4-format file. Addresses are in the eboot's first segment.
    private func xml(ids: [String] = ["CUSA03173"], patches: String) -> String {
        let idList = ids.map { "<ID>\($0)</ID>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <Patch><TitleID>\(idList)</TitleID><Metadata Title="Bloodborne" Name="x" AppVer="01.08">
        <PatchList><Line Type="bytes" Address="0x401000" Value="90"/></PatchList></Metadata>\(patches)</Patch>
        """
    }

    private static let fixturePatches = """
        <Metadata Title="Bloodborne" Name="Nop pair" Author="tester" Note="First line.\\nSecond line." AppVer="01.09" AppElf="eboot.bin" isEnabled="false">
          <PatchList><Line Type="bytes" Address="0x401000" Value="90 90"/></PatchList></Metadata>
        <Metadata Title="Bloodborne" Name="Int3" Author="tester" AppVer="01.09" AppElf="eboot.bin" isEnabled="true">
          <PatchList><Line Type="bytes" Address="0x401010" Value="CC"/></PatchList></Metadata>
        <Metadata Title="Bloodborne" Name="Float" AppVer="01.09" isEnabled="false">
          <PatchList><Line Type="float32" Address="0x401020" Value="1.5"/></PatchList></Metadata>
        <Metadata Title="Bloodborne" Name="Other module" AppVer="01.09" AppElf="sce_module/x.prx" isEnabled="true">
          <PatchList><Line Type="bytes" Address="0x401030" Value="90"/></PatchList></Metadata>
        """

    private func writeExternal(_ name: String, _ text: String) throws {
        try text.write(to: dirs.patchesDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func python(_ arguments: [String], cwd: URL = PatchStoreTests.repo, environment: [String: String] = env) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + arguments
        process.environment = environment
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Built-in list

    func testBuiltInCategories() throws {
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        let byName = Dictionary(uniqueKeysWithValues: store.builtIn.map { ($0.name, $0) })
        XCTAssertGreaterThan(store.builtIn.count, 50)
        XCTAssertEqual(byName["60 FPS++"]?.category, .frameRate)
        XCTAssertEqual(byName["Sprint Fix (High FPS)"]?.category, .frameRate)
        XCTAssertEqual(byName["Disable DoF"]?.category, .graphicsManaged)
        XCTAssertEqual(byName["Model LOD 1 (Lower)"]?.category, .graphicsManaged)
        XCTAssertEqual(byName["Resolution Patch 1280x720 (16:9)"]?.category, .graphicsManaged)
        XCTAssertEqual(byName["Increased Graphics Heap Sizes"]?.category, .graphicsManaged)
        XCTAssertEqual(byName["Skip Online/Offline Choice"]?.category, .network)
        for extra in ["Skip Intro", "30 FPS++", "Restore Debug Camera", "Enemy Control", "Intel Black Tonemap Fix"] {
            XCTAssertEqual(byName[extra]?.category, .extra, extra)
        }
        // Metadata of the XML.
        let intro = try XCTUnwrap(byName["Skip Intro"])
        XCTAssertEqual(intro.id, "builtin/Skip Intro")
        XCTAssertEqual(intro.author, "illusion")
        XCTAssertTrue(intro.defaultOn)
        XCTAssertEqual(intro.source, .builtIn)
        XCTAssertTrue(store.external.isEmpty)
    }

    /// The category tables match patches.py's: FPS_PRESETS, EFFECTS, MODEL_LOD and the network patch.
    func testCategoriesMatchPatchesPy() throws {
        let script = """
        import json, sys
        sys.path.insert(0, 'scripts')
        import patches as p
        print(json.dumps({'fps': p.FPS_PRESETS,
                          'effects': [v for pair in p.EFFECTS.values() for v in pair if v],
                          'lod': p.MODEL_LOD, 'network': p.SKIP_NETWORK_CHOICE, 'intel': p.INTEL_TONEMAP,
                          'resolution': p.RESOLUTION_TEMPLATE}))
        """
        let result = try python(["-c", script])
        XCTAssertEqual(result.status, 0, result.output)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let fps = try XCTUnwrap(object["fps"] as? [String: [String]])
        for rate in FrameRate.allCases {
            XCTAssertEqual(PatchStore.frameRatePatches(rate), fps[rate.rawValue], "fps \(rate.rawValue)")
        }
        XCTAssertEqual(Set(PatchStore.frameRateNames), Set(fps.values.flatMap { $0 }))
        // Effects: the seven the launcher has switches for are managed; the other three are extras.
        let effects = Set(try XCTUnwrap(object["effects"] as? [String]))
        XCTAssertEqual(effects.subtracting(PatchStore.effectPatches.keys),
                       ["Skip Intro", "Restore Debug Camera", "Restore Debug Menu (READ NOTES)"])
        XCTAssertTrue(Set(PatchStore.effectPatches.keys).isSubset(of: effects))
        XCTAssertEqual(Set(try XCTUnwrap(object["lod"] as? [String: String]).values), Set(PatchStore.modelLODPatches.keys))
        XCTAssertEqual(object["network"] as? String, PatchStore.networkPatch)
        XCTAssertEqual(PatchStore.category(ofBuiltIn: try XCTUnwrap(object["resolution"] as? String)), .graphicsManaged)
        XCTAssertEqual(PatchStore.category(ofBuiltIn: try XCTUnwrap(object["intel"] as? String)), .extra)
        // Every name patches.py applies by itself is in the built-in file.
        let names = Set(PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir).builtIn.map(\.name))
        XCTAssertTrue(effects.union(PatchStore.frameRateNames).union(PatchStore.modelLODPatches.keys)
            .union([PatchStore.networkPatch]).isSubset(of: names))
    }

    func testFrameRatePatchesFollowTheProfile() {
        var profile = Profile.vanilla
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        let frame = store.builtIn.filter { $0.category == .frameRate }
        func on() -> [String] { frame.filter { PatchStore.frameRatePatchIsOn($0, in: profile) }.map(\.name).sorted() }
        profile.frameRate = .fps30
        XCTAssertEqual(on(), [])
        profile.frameRate = .fps60
        XCTAssertEqual(on(), ["60 FPS++"])
        profile.frameRate = .fps90
        XCTAssertEqual(on(), ["90 FPS++", "Sprint Fix (High FPS)"])
        profile.frameRate = .uncapped
        XCTAssertEqual(on(), ["Sprint Fix (High FPS)", "Uncap FPS++"])
    }

    func testManagedState() throws {
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        let byName = Dictionary(uniqueKeysWithValues: store.builtIn.map { ($0.name, $0) })
        var profile = Profile.vanilla
        var settings = LauncherSettings()
        let dof = try XCTUnwrap(byName["Disable DoF"]), ssr = try XCTUnwrap(byName["Enable Screen Space Reflections (READ NOTE)"])
        XCTAssertEqual(PatchStore.managedState(dof, profile: profile, settings: settings), false)
        XCTAssertEqual(PatchStore.managedState(ssr, profile: profile, settings: settings), false)
        profile.effects[.depthOfField] = false
        profile.effects[.reflections] = true
        XCTAssertEqual(PatchStore.managedState(dof, profile: profile, settings: settings), true)
        XCTAssertEqual(PatchStore.managedState(ssr, profile: profile, settings: settings), true)
        profile.modelLOD = 1
        XCTAssertEqual(PatchStore.managedState(try XCTUnwrap(byName["Model LOD 1 (Lower)"]), profile: profile, settings: settings), true)
        XCTAssertEqual(PatchStore.managedState(try XCTUnwrap(byName["Model LOD 2 (Lowest)"]), profile: profile, settings: settings), false)
        let network = try XCTUnwrap(byName["Skip Online/Offline Choice"])
        XCTAssertEqual(PatchStore.managedState(network, profile: profile, settings: settings), true)
        settings.skipNetworkChoice = false
        XCTAssertEqual(PatchStore.managedState(network, profile: profile, settings: settings), false)
    }

    // MARK: External files

    func testExternalFiles() throws {
        try writeExternal("good.xml", xml(patches: Self.fixturePatches))
        try writeExternal("other-game.xml", xml(ids: ["CUSA99999"], patches: Self.fixturePatches))
        try writeExternal("broken.xml", "<Patch><Metadata")
        try writeExternal("none.xml", xml(patches: ""))
        try writeExternal("UPPER.XML", xml(patches: Self.fixturePatches))
        try writeExternal(".hidden.xml", xml(patches: Self.fixturePatches))
        try "text".write(to: dirs.patchesDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        XCTAssertEqual(store.files.map(\.name), ["broken.xml", "good.xml", "none.xml", "other-game.xml"])
        let byName = Dictionary(uniqueKeysWithValues: store.files.map { ($0.name, $0) })
        guard case .unreadable? = byName["broken.xml"]?.problem else { return XCTFail("broken.xml: \(String(describing: byName["broken.xml"]?.problem))") }
        XCTAssertEqual(byName["other-game.xml"]?.problem, .otherGame)
        XCTAssertEqual(byName["none.xml"]?.problem, .noPatches)
        XCTAssertNil(byName["good.xml"]?.problem)

        // The eboot patches of 01.09 (the AppVer 01.08 and the other module's are not listed).
        let patches = try XCTUnwrap(byName["good.xml"]).patches
        XCTAssertEqual(patches.map(\.id), ["good.xml/Nop pair", "good.xml/Int3", "good.xml/Float"])
        XCTAssertEqual(patches.map(\.defaultOn), [false, true, false])
        XCTAssertEqual(patches[0].author, "tester")
        XCTAssertEqual(patches[0].note, "First line.\nSecond line.")
        XCTAssertEqual(patches[0].source, .external(file: "good.xml"))
        XCTAssertTrue(patches.allSatisfy { $0.category == .extra })
    }

    /// A file without title ids is for every game (patches.py: `if ids and not ids & ...`).
    func testFileWithoutTitleIDsIsAccepted() throws {
        try writeExternal("noids.xml", xml(ids: [], patches: Self.fixturePatches))
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        XCTAssertEqual(store.files.first?.patches.count, 3)
    }

    /// The built-in file in the patches folder is not an external file (patches.py `exclude`).
    func testBuiltInFileIsNotExternal() throws {
        let link = dirs.patchesDir.appendingPathComponent("Bloodborne.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.builtInXML)
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        XCTAssertTrue(store.files.isEmpty)
    }

    func testImport() throws {
        let source = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String) throws -> URL {
            let url = source.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        XCTAssertEqual(try PatchStore.importXML(from: file("mine.xml", xml(patches: Self.fixturePatches)), into: dirs), "mine.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirs.patchesDir.appendingPathComponent("mine.xml").path))
        // The same name again replaces the file.
        try PatchStore.importXML(from: file("mine.xml", xml(patches: Self.fixturePatches + "<!-- v2 -->")), into: dirs)
        XCTAssertTrue(try String(contentsOf: dirs.patchesDir.appendingPathComponent("mine.xml"), encoding: .utf8).contains("v2"))

        XCTAssertThrowsError(try PatchStore.importXML(from: file("game.xml", xml(ids: ["CUSA11111"], patches: Self.fixturePatches)), into: dirs)) {
            XCTAssertEqual($0 as? PatchStore.ImportError, .otherGame)
        }
        XCTAssertThrowsError(try PatchStore.importXML(from: file("empty.xml", xml(patches: "")), into: dirs)) {
            XCTAssertEqual($0 as? PatchStore.ImportError, .noPatches)
        }
        XCTAssertThrowsError(try PatchStore.importXML(from: file("bad.xml", "not xml at all"), into: dirs)) {
            guard case .unreadable? = $0 as? PatchStore.ImportError else { return XCTFail("\($0)") }
            XCTAssertNotNil(($0 as? LocalizedError)?.errorDescription)
        }
        XCTAssertEqual(PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir).files.map(\.name), ["mine.xml"])
    }

    // MARK: Choices, patches.json, BB_PATCHES

    func testChoicesKeepOnlyDifferences() throws {
        try writeExternal("good.xml", xml(patches: Self.fixturePatches))
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        let nop = store.external[0], int3 = store.external[1]
        var profile = Profile.vanilla
        XCTAssertFalse(PatchStore.isOn(nop, in: profile))
        XCTAssertTrue(PatchStore.isOn(int3, in: profile))

        profile = PatchStore.setting(nop, on: true, in: profile)
        profile = PatchStore.setting(int3, on: false, in: profile)
        XCTAssertEqual(profile.patches, ["good.xml/Nop pair": true, "good.xml/Int3": false])
        XCTAssertTrue(PatchStore.isOn(nop, in: profile))
        XCTAssertFalse(PatchStore.isOn(int3, in: profile))
        // Back to the default: the entry goes.
        profile = PatchStore.setting(nop, on: false, in: profile)
        XCTAssertEqual(profile.patches, ["good.xml/Int3": false])

        let intro = try XCTUnwrap(store.builtIn.first { $0.name == "Skip Intro" })
        XCTAssertFalse(PatchStore.isOn(intro, in: profile), "a built-in extra is off until chosen, whatever its isEnabled says")
        profile = PatchStore.setting(intro, on: true, in: profile)
        XCTAssertEqual(profile.patches["builtin/Skip Intro"], true)
        profile = PatchStore.setting(intro, on: false, in: profile)
        XCTAssertNil(profile.patches["builtin/Skip Intro"])
    }

    func testPatchesJSON() throws {
        var profile = Profile.vanilla
        profile.patches = ["b.xml/On": true, "a.xml/Off": false, "a.xml/On 2": true, "builtin/Skip Intro": true]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: PatchStore.patchesJSON(for: profile)) as? [String: [String]])
        XCTAssertEqual(object["enabled"], ["a.xml/On 2", "b.xml/On"])
        XCTAssertEqual(object["disabled"], ["a.xml/Off"])
        XCTAssertEqual(object.keys.sorted(), ["disabled", "enabled"])
        // Empty choices: the file patches.py reads without changing a default.
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: PatchStore.patchesJSON(for: .vanilla)) as? [String: [String]])
        XCTAssertEqual(empty, ["enabled": [], "disabled": []])
        XCTAssertEqual(PatchStore.patchesJSON(for: profile), PatchStore.patchesJSON(for: profile))
    }

    func testExtraNames() throws {
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        var profile = Profile.vanilla
        XCTAssertEqual(store.extraNames(for: profile), "")
        // XML order; a managed or unknown name and an "off" entry are not passed on.
        profile.patches = ["builtin/Skip Intro": true, "builtin/30 FPS++": true, "builtin/Enemy Control": false,
                           "builtin/Disable DoF": true, "builtin/Nonexistent": true, "x.xml/Y": true]
        let names = store.extraNames(for: profile).split(separator: ";").map(String.init)
        XCTAssertEqual(Set(names), ["Skip Intro", "30 FPS++"])
        XCTAssertEqual(names.first, "Skip Intro", "the XML lists Skip Intro first")
        // Without a built-in list: unchecked, sorted.
        XCTAssertEqual(PatchStore.extraNames(for: profile), "30 FPS++;Disable DoF;Nonexistent;Skip Intro")
        profile.patches = ["builtin/Restore Debug Camera": true, "builtin/Enemy Control": true]
        XCTAssertNotNil(PatchStore.conflict(in: profile))
    }

    func testLaunchSpecCarriesExtras() {
        let runtime = Runtime(probe: URL(fileURLWithPath: "/x/bb-probe"), pipeline: Self.repo,
                              python: URL(fileURLWithPath: "/usr/bin/python3"), repository: Self.repo)
        func spec(_ extras: String, environment: [String: String] = [:], base: [String: String] = [:]) -> LaunchSpec {
            var profile = Profile.vanilla
            profile.environment = environment
            return LaunchSpec.make(LaunchInputs(profile: profile, gameDir: root, preparedDir: root, dirs: dirs, runtime: runtime,
                                                settings: LauncherSettings(), scaled: nil, patchExtras: extras,
                                                appleSilicon: true, macOSMajor: 15), baseEnvironment: base)
        }
        func extra(_ spec: LaunchSpec) -> String? {
            let step = spec.steps.first { $0.script == "patches.py" }
            return step?.arguments[(step?.arguments.firstIndex(of: "--extra") ?? 0) + 1]
        }
        XCTAssertEqual(extra(spec("Skip Intro;30 FPS++")), "Skip Intro;30 FPS++")
        XCTAssertEqual(spec("Skip Intro").environment["BB_PATCHES"], "Skip Intro")
        XCTAssertEqual(extra(spec("")), "")
        XCTAssertNil(spec("").environment["BB_PATCHES"])
        // An expert BB_PATCHES wins; an inherited one stays when the profile chooses nothing.
        XCTAssertEqual(extra(spec("Skip Intro", environment: ["BB_PATCHES": "Enemy Control"])), "Enemy Control")
        XCTAssertEqual(extra(spec("", base: ["BB_PATCHES": "Enemy Control"])), "Enemy Control")
    }

    // MARK: The same patches.bin as run.sh

    /// The launcher's selection (a built-in extra, an external patch on against its default, one
    /// off against it) gives the same patches.bin as run.sh with BB_PATCHES and BB_PATCHES_CONFIG.
    /// Needs the real game for a prepared eboot.elf: LANTERN_REAL_GAME=<game folder> (read only).
    func testSamePatchesBinAsRunSh() throws {
        guard let path = ProcessInfo.processInfo.environment["LANTERN_REAL_GAME"] else {
            throw XCTSkip("set LANTERN_REAL_GAME=<game folder> to compare with run.sh")
        }
        let game = URL(fileURLWithPath: path, isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: game.appendingPathComponent("eboot.bin").path))
        let fm = FileManager.default
        let prepared = root.appendingPathComponent("prepared", isDirectory: true)
        let prepare = try python(["scripts/prepare.py", game.path, "--out", prepared.path])
        XCTAssertEqual(prepare.status, 0, prepare.output)
        let elf = prepared.appendingPathComponent("eboot.elf")
        XCTAssertTrue(fm.fileExists(atPath: elf.path))

        try writeExternal("good.xml", xml(patches: Self.fixturePatches))
        let store = PatchStore.load(builtInXML: Self.builtInXML, patchesDir: dirs.patchesDir)
        var profile = Profile.vanilla
        profile.frameRate = .fps60
        profile = PatchStore.setting(try XCTUnwrap(store.builtIn.first { $0.name == "Skip Intro" }), on: true, in: profile)
        profile = PatchStore.setting(try XCTUnwrap(store.external.first { $0.name == "Nop pair" }), on: true, in: profile)   // default off
        profile = PatchStore.setting(try XCTUnwrap(store.external.first { $0.name == "Int3" }), on: false, in: profile)      // default on

        // (a) The launcher: patches.json and BB_PATCHES from the profile, the LaunchSpec's step.
        try PatchStore.patchesJSON(for: profile).write(to: dirs.patchesConfig, options: .atomic)
        let extras = store.extraNames(for: profile)
        XCTAssertEqual(extras, "Skip Intro")
        let runtime = Runtime(probe: URL(fileURLWithPath: "/x/bb-probe"), pipeline: Self.repo,
                              python: URL(fileURLWithPath: "/usr/bin/python3"), repository: Self.repo)
        func launcherBin(_ profile: Profile, extras: String) throws -> (Data, String) {
            let spec = LaunchSpec.make(LaunchInputs(profile: profile, gameDir: game, preparedDir: prepared, dirs: dirs,
                                                    runtime: runtime, settings: LauncherSettings(), scaled: nil,
                                                    patchExtras: extras, appleSilicon: true, macOSMajor: 15))
            let step = try XCTUnwrap(spec.steps.first { $0.script == "patches.py" })
            var environment = Self.env
            environment.merge(spec.environment) { $1 }
            let result = try python(["scripts/patches.py"] + step.arguments, environment: environment)
            XCTAssertEqual(result.status, 0, result.output)
            return (try Data(contentsOf: prepared.appendingPathComponent("patches.bin")), result.output)
        }
        let (a, log) = try launcherBin(profile, extras: extras)
        XCTAssertTrue(log.contains("external good.xml/Nop pair"), log)
        XCTAssertFalse(log.contains("good.xml/Int3"), log)
        XCTAssertTrue(log.contains("Skip Intro"), log)
        // Without the selection the file differs: the choices reach the result.
        var unchanged = Profile.vanilla
        unchanged.frameRate = .fps60
        let (baseline, _) = try launcherBin(unchanged, extras: "")
        XCTAssertNotEqual(a, baseline)

        // (b) run.sh: BB_PATCHES and the same patches.json through BB_PATCHES_CONFIG.
        let data = root.appendingPathComponent("shell", isDirectory: true)
        let shellOut = data.appendingPathComponent("out/game", isDirectory: true)
        try fm.createDirectory(at: shellOut, withIntermediateDirectories: true)
        try fm.copyItem(at: elf, to: shellOut.appendingPathComponent("eboot.elf"))
        let config = data.appendingPathComponent("patches.json")
        try PatchStore.patchesJSON(for: profile).write(to: config)
        var environment = Self.env
        environment.merge(["PYTHON": "python3", "BB_DATA_DIR": data.path, "BB_GAME_DIR": game.path, "BB_FPS": "60",
                           "BB_PATCHES": extras, "BB_PATCHES_CONFIG": config.path,
                           "BB_PATCHES_DIR": dirs.patchesDir.path]) { $1 }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = [Self.repo.appendingPathComponent("macos/run.sh").path, "--print-env"]
        shell.environment = environment
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        let step = try XCTUnwrap(LaunchSpecTests.parse(printed).steps.first { $0.script == "patches.py" })
        let result = try python(["scripts/patches.py"] + step.arguments, environment: Self.env)
        XCTAssertEqual(result.status, 0, result.output)
        let b = try Data(contentsOf: shellOut.appendingPathComponent("patches.bin"))
        XCTAssertGreaterThan(a.count, 24)
        XCTAssertEqual(a, b, "patches.bin differs between the launcher and run.sh")
    }
}
