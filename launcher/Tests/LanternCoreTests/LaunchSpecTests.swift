// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

/// LaunchSpec.make against the real macos/run.sh --print-env.
final class LaunchSpecTests: XCTestCase {
    // MARK: Harness

    /// The repository root (this file is launcher/Tests/LanternCoreTests/LaunchSpecTests.swift).
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// PATH of the child processes: run.sh needs sysctl (/usr/sbin) for the automatic renderer.
    static let path = "/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin"

    struct Output {
        var stdout: String
        var status: Int32
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(stdout: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }

    /// Undoes printf %q: backslash escapes and '...' quotes, tokens split at unescaped blanks.
    static func unquote(_ line: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quoted = false
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; continue }
            if quoted {
                if ch == "'" { quoted = false } else { current.append(ch) }
                continue
            }
            switch ch {
            case "\\": escaped = true; inToken = true
            case "'": quoted = true; inToken = true
            case " ":
                if inToken { tokens.append(current); current = ""; inToken = false }
            default: current.append(ch); inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    struct PrintEnv {
        var steps: [LaunchSpec.Step] = []
        var exec = ""
        var arguments: [String] = []
        var environment: [String: String] = [:]
    }

    static func parse(_ text: String) -> PrintEnv {
        var result = PrintEnv()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("step ") {
                let tokens = unquote(line.dropFirst(5))
                // python3 scripts/X.py args...
                let script = (tokens[1] as NSString).lastPathComponent
                result.steps.append(LaunchSpec.Step(script: script, arguments: Array(tokens.dropFirst(2))))
            } else if line.hasPrefix("exec ") {
                result.exec = String(line.dropFirst(5))
            } else if line.hasPrefix("arg ") {
                result.arguments.append(String(line.dropFirst(4)))
            } else if line.hasPrefix("env ") {
                let item = line.dropFirst(4)
                if let eq = item.firstIndex(of: "=") {
                    result.environment[String(item[..<eq])] = String(item[item.index(after: eq)...])
                }
            }
        }
        return result
    }

    /// One case's folders: data dir D, bbport.ini, a game folder with an eboot.bin, a probe.
    struct Fixture {
        var root: URL
        var dirs: DataDirs
        var game: URL
        var prepared: URL
        var runtime: Runtime
    }

    func makeFixture(ini: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lantern-spec-" + UUID().uuidString)
        let fm = FileManager.default
        let game = root.appendingPathComponent("G", isDirectory: true)
        let data = root.appendingPathComponent("D", isDirectory: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try fm.createDirectory(at: data.appendingPathComponent("out"), withIntermediateDirectories: true)
        fm.createFile(atPath: game.appendingPathComponent("eboot.bin").path, contents: Data())
        let probe = data.appendingPathComponent("out/bb-probe")
        fm.createFile(atPath: probe.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let dirs = DataDirs(root: data)
        try ini.write(to: dirs.iniFile, atomically: true, encoding: .utf8)
        let runtime = Runtime(probe: probe, pipeline: Self.repo, python: URL(fileURLWithPath: "/usr/bin/python3"),
                              repository: Self.repo)
        return Fixture(root: root, dirs: dirs, game: game,
                       prepared: data.appendingPathComponent("out/game", isDirectory: true), runtime: runtime)
    }

    /// patches.py --print-scaled, as the launcher computes the inputs' sizes.
    func scaledSizes(_ fixture: Fixture) throws -> ScaledSizes? {
        let env = ["HOME": NSHomeDirectory(), "PATH": Self.path]
        let script = Self.repo.appendingPathComponent("scripts/patches.py").path
        let out = try run("/usr/bin/env", ["python3", script, "--print-scaled", "--settings", fixture.dirs.iniFile.path],
                          environment: env)
        XCTAssertEqual(out.status, 0)
        let parts = out.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
        return parts.count == 2 ? ScaledSizes(render: parts[0], output: parts[1]) : nil
    }

    static var hostAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    func inputs(_ profile: Profile, _ fixture: Fixture, settings: LauncherSettings = LauncherSettings(),
                scaled: ScaledSizes?) -> LaunchInputs {
        LaunchInputs(profile: profile, gameDir: fixture.game, preparedDir: fixture.prepared, dirs: fixture.dirs,
                     runtime: fixture.runtime, settings: settings, scaled: scaled,
                     appleSilicon: Self.hostAppleSilicon,
                     macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    struct Case {
        var name: String
        var profile: Profile
        /// The variables run.sh gets (besides HOME, PATH, PYTHON, BB_DATA_DIR, BB_GAME_DIR).
        var runEnv: [String: String] = [:]
        var ini: String = ""
        /// run.sh variables with no counterpart in the spec's environment.
        var dropFromRunSh: Set<String> = []
    }

    func check(_ c: Case) throws {
        let fixture = try makeFixture(ini: c.ini)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var env = ["HOME": NSHomeDirectory(), "PATH": Self.path, "PYTHON": "python3",
                   "BB_DATA_DIR": fixture.dirs.root.path, "BB_GAME_DIR": fixture.game.path]
        env.merge(c.runEnv) { $1 }
        let shell = try run("/bin/bash", [Self.repo.appendingPathComponent("macos/run.sh").path, "--print-env"],
                            environment: env)
        XCTAssertEqual(shell.status, 0, c.name)
        var expected = Self.parse(shell.stdout)
        for name in c.dropFromRunSh { expected.environment[name] = nil }

        let scaled = try scaledSizes(fixture)
        let spec = LaunchSpec.make(inputs(c.profile, fixture, scaled: scaled),
                                   baseEnvironment: ["BB_DATA_DIR": fixture.dirs.root.path])

        XCTAssertEqual(spec.environment, expected.environment, c.name)
        XCTAssertEqual(spec.arguments, expected.arguments, c.name)
        XCTAssertEqual(spec.executable.path, expected.exec, c.name)
        XCTAssertEqual(spec.steps, expected.steps, c.name)
        XCTAssertEqual(spec.workingDirectory, fixture.dirs.runDir, c.name)
    }

    // MARK: Matrix against run.sh

    private func profile(_ fps: FrameRate, _ edit: (inout Profile) -> Void = { _ in }) -> Profile {
        var p = Profile.vanilla
        p.frameRate = fps
        edit(&p)
        return p
    }

    func testDefault() throws {
        // run.sh without BB_FPS is "uncap"; the profile always names its rate.
        try check(Case(name: "default", profile: profile(.uncapped), runEnv: ["BB_FPS": "uncap"]))
    }

    func testFrameRates() throws {
        for (fps, name) in [(FrameRate.fps30, "30"), (.fps60, "60"), (.fps90, "90")] {
            try check(Case(name: "fps " + name, profile: profile(fps), runEnv: ["BB_FPS": name]))
        }
    }

    func testVulkan() throws {
        try check(Case(name: "vulkan", profile: profile(.uncapped) { $0.renderer = .vulkan },
                       runEnv: ["BB_FPS": "uncap", "BB_RENDERER": "vulkan"]))
    }

    func testMetal() throws {
        try check(Case(name: "metal", profile: profile(.fps60) { $0.renderer = .metal },
                       runEnv: ["BB_FPS": "60", "BB_RENDERER": "metal"]))
    }

    func testAir() throws {
        let fixture = try makeFixture(ini: "")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let env = ["HOME": NSHomeDirectory(), "PATH": Self.path, "PYTHON": "python3",
                   "BB_DATA_DIR": fixture.dirs.root.path, "BB_GAME_DIR": fixture.game.path, "BB_PROFILE": "m4air"]
        let shell = try run("/bin/bash", [Self.repo.appendingPathComponent("macos/run.sh").path, "--print-env"],
                            environment: env)
        // run.sh's BB_SETTINGS are the Air profile's ini keys.
        let settings = try XCTUnwrap(Self.parse(shell.stdout).environment["BB_SETTINGS"])
        let keys = Dictionary(uniqueKeysWithValues: Profile.air.iniKeys)
        XCTAssertFalse(settings.isEmpty)
        for item in settings.split(separator: ",") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(keys[pair[0]], pair[1], "air ini key \(pair[0])")
        }
        try check(Case(name: "m4air", profile: .air, runEnv: ["BB_PROFILE": "m4air"],
                       dropFromRunSh: ["BB_SETTINGS", "BB_PROFILE"]))
    }

    func testOutputOtherThan1080p() throws {
        let ini = "output_res=2560x1440\nupscaler=fsr3\npreset=1\n"
        let fixture = try makeFixture(ini: ini)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let scaled = try XCTUnwrap(scaledSizes(fixture), "patches.py --print-scaled printed nothing")
        XCTAssertEqual(scaled.output, "2560x1440")
        try check(Case(name: "1440p", profile: profile(.fps60), runEnv: ["BB_FPS": "60"], ini: ini))
        // A set render size wins over the scaled one.
        try check(Case(name: "1440p, render size", profile: profile(.fps60) { $0.renderResolution = "1280x720" },
                       runEnv: ["BB_FPS": "60", "BB_RENDER_RES": "1280x720"], ini: ini))
    }

    func testExpertVariables() throws {
        try check(Case(name: "expert", profile: profile(.fps60) { $0.environment = ["BB_VBLANK_HZ": "120"] },
                       runEnv: ["BB_FPS": "60", "BB_VBLANK_HZ": "120"]))
        // An expert variable beats the profile's own: BB_FPS from the environment.
        try check(Case(name: "expert fps", profile: profile(.fps60) { $0.environment = ["BB_FPS": "90"] },
                       runEnv: ["BB_FPS": "90"]))
    }

    // MARK: Swift only

    func testOwnSaves() throws {
        let fixture = try makeFixture(ini: "")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var p = profile(.fps60)
        p.id = "mine"
        p.ownSaves = true
        let spec = LaunchSpec.make(inputs(p, fixture, scaled: nil))
        let index = try XCTUnwrap(spec.arguments.firstIndex(of: "--user"))
        XCTAssertEqual(spec.arguments[index + 1], fixture.dirs.profileUserDir("mine").path)
        XCTAssertEqual(spec.environment["BB_GPU_USER_DIR"], fixture.dirs.userDir.path)

        p.ownSaves = false
        let shared = LaunchSpec.make(inputs(p, fixture, scaled: nil))
        let sharedIndex = try XCTUnwrap(shared.arguments.firstIndex(of: "--user"))
        XCTAssertEqual(shared.arguments[sharedIndex + 1], fixture.dirs.userDir.path)
        XCTAssertEqual(shared.environment["BB_GPU_USER_DIR"], fixture.dirs.userDir.path)
    }

    func testLauncherSettings() throws {
        let fixture = try makeFixture(ini: "")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plain = LaunchSpec.make(inputs(.vanilla, fixture, scaled: nil))
        for name in ["BB_FULLSCREEN", "BB_DISPLAY", "BB_GAMEPAD", "BB_LANGUAGE", "BB_SKIP_NETWORK_CHOICE"] {
            XCTAssertNil(plain.environment[name], name)
        }
        var settings = LauncherSettings()
        settings.fullscreen = true
        settings.display = 1
        settings.gamepad = "DualSense"
        settings.gameLanguage = "4"
        settings.skipNetworkChoice = false
        let spec = LaunchSpec.make(inputs(.vanilla, fixture, settings: settings, scaled: nil),
                                   baseEnvironment: ["HOME": "/x", "BB_TIMEOUT": "5"])
        XCTAssertEqual(spec.environment["BB_FULLSCREEN"], "1")
        XCTAssertEqual(spec.environment["BB_DISPLAY"], "1")
        XCTAssertEqual(spec.environment["BB_GAMEPAD"], "DualSense")
        XCTAssertEqual(spec.environment["BB_LANGUAGE"], "4")
        XCTAssertEqual(spec.environment["BB_SKIP_NETWORK_CHOICE"], "0")
        XCTAssertNil(spec.environment["HOME"])
        XCTAssertEqual(spec.arguments.last, "5")
    }
}
