// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Where the game runtime and the pipeline are: inside the app bundle (D3), or in a repository
/// checkout for the dev build (L-M1; launcher/build.sh --dev writes LanternRepository into the
/// app's Info.plist, LANTERN_REPO overrides it).
public struct Runtime: Sendable, Equatable {
    /// bb-probe (inside "Hunter's Lantern Game.app" when bundled).
    public var probe: URL
    /// The folder holding scripts/*.py and patches/Bloodborne.xml (patches.py finds the XML
    /// next to its own folder).
    public var pipeline: URL
    /// The Python interpreter for the pipeline (embedded in the bundle, D4).
    public var python: URL
    /// The repository root for a dev build, nil when bundled.
    public var repository: URL?

    public init(probe: URL, pipeline: URL, python: URL, repository: URL? = nil) {
        self.probe = probe
        self.pipeline = pipeline
        self.python = python
        self.repository = repository
    }

    public var scripts: URL { pipeline.appendingPathComponent("scripts", isDirectory: true) }
    public var patchesXML: URL { pipeline.appendingPathComponent("patches/Bloodborne.xml") }

    public enum LocateError: Error, Equatable, LocalizedError, CustomStringConvertible {
        case notFound(String)
        public var errorDescription: String? {
            switch self {
            case .notFound(let what): return String(localized: "The game runtime is missing: \(what)", bundle: .resources)
            }
        }
        public var description: String { errorDescription ?? "" }
    }

    /// The bundled runtime, else the repository's.
    public static func locate(bundle: Bundle = .main,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Runtime {
        let fm = FileManager.default
        let contents = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let gameApp = contents.appendingPathComponent("Helpers/Hunter's Lantern Game.app", isDirectory: true)
        let bundledProbe = gameApp.appendingPathComponent("Contents/MacOS/bb-probe")
        if environment["LANTERN_REPO"] == nil, fm.isExecutableFile(atPath: bundledProbe.path) {
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            let runtime = Runtime(probe: bundledProbe,
                                  pipeline: resources.appendingPathComponent("pipeline", isDirectory: true),
                                  python: resources.appendingPathComponent("python/bin/python3"))
            guard fm.isExecutableFile(atPath: runtime.python.path) else { throw LocateError.notFound(runtime.python.path) }
            return runtime
        }
        let repoPath = environment["LANTERN_REPO"] ?? bundle.object(forInfoDictionaryKey: "LanternRepository") as? String
        guard let repoPath, !repoPath.isEmpty else { throw LocateError.notFound("Hunter's Lantern Game.app") }
        let repo = URL(fileURLWithPath: repoPath, isDirectory: true)
        let probe = repo.appendingPathComponent("macos/out/bb-probe")
        guard fm.isExecutableFile(atPath: probe.path) else { throw LocateError.notFound(probe.path + " (bash macos/build.sh)") }
        guard let python = devPython(environment: environment) else { throw LocateError.notFound("python3") }
        return Runtime(probe: probe, pipeline: repo, python: python, repository: repo)
    }

    /// A dev build's Python: PYTHON, else python3 from Homebrew or the Command Line Tools (a
    /// bundled launcher never gets here and never runs /usr/bin/python3, D4).
    static func devPython(environment: [String: String]) -> URL? {
        var candidates: [String] = []
        if let python = environment["PYTHON"], !python.isEmpty { candidates.append(python) }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
