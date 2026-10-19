// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One patch of an XML patch file (GoldHEN/shadPS4 format): a `Metadata` element.
public struct Patch: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// patches/Bloodborne.xml.
        case builtIn
        /// A file in DataDirs.patchesDir (its name).
        case external(file: String)
    }

    /// Where the launcher decides what a patch is (scripts/patches.py applies them).
    public enum Category: Equatable, Sendable {
        /// patches.py FPS_PRESETS: follows the profile's frame rate, never chosen by hand.
        case frameRate
        /// Effects, model detail, the render size's patches: the Graphics page decides (through
        /// bbport.ini and BB_RENDER_RES).
        case graphicsManaged
        /// The online/offline dialog: the Advanced page (BB_SKIP_NETWORK_CHOICE).
        case network
        /// A built-in patch the user may add (BB_PATCHES), or any external patch.
        case extra
    }

    /// The key a profile (`Profile.patches`) and patches.json use: an external patch's is
    /// patches.py's "<file name>/<patch name>", a built-in one's is "builtin/<patch name>" (no
    /// external key starts like that: those files end in ".xml").
    public var id: String
    public var name: String
    public var author: String
    public var note: String
    public var source: Source
    /// The XML's isEnabled.
    public var defaultOn: Bool
    public var category: Category

    public init(id: String, name: String, author: String = "", note: String = "", source: Source,
                defaultOn: Bool = false, category: Category) {
        self.id = id
        self.name = name
        self.author = author
        self.note = note
        self.source = source
        self.defaultOn = defaultOn
        self.category = category
    }

    public var isBuiltIn: Bool { source == .builtIn }
}

/// One XML file in the patches folder.
public struct PatchFile: Identifiable, Equatable, Sendable {
    public enum Problem: Equatable, Sendable {
        /// patches.py skips a file that does not parse.
        case unreadable(String)
        /// The file's title ids are other games'.
        case otherGame
        /// No eboot patch for app version 01.09.
        case noPatches
    }

    public var name: String
    public var url: URL
    public var patches: [Patch]
    public var problem: Problem?
    public var id: String { name }
}

/// The patch lists (L3.5, D7): the built-in patches/Bloodborne.xml and the user's XML files, the
/// profile's choices, and what the launch needs from them: patches.json and BB_PATCHES.
///
/// A profile's `patches` maps a patch key (`Patch.id`) to a choice:
/// - external patch: only a switch against the XML's isEnabled is stored (true: on, false: off);
///   patches.py's patches.json is written from them ({"enabled": [...], "disabled": [...]}).
/// - built-in extra ("builtin/<name>"): true adds it (BB_PATCHES); off is the absence of the key.
/// Frame-rate patches follow the profile's frame rate; effect, model detail and size patches the
/// Graphics page; the online choice the Advanced page.
public struct PatchStore: Sendable, Equatable {
    public private(set) var builtIn: [Patch]
    public private(set) var files: [PatchFile]

    public var external: [Patch] { files.flatMap(\.patches) }

    public init(builtIn: [Patch] = [], files: [PatchFile] = []) {
        self.builtIn = builtIn
        self.files = files
    }

    /// The built-in file and the patches folder of this runtime and data folder.
    public static func load(runtime: Runtime, dirs: DataDirs) -> PatchStore {
        load(builtInXML: runtime.patchesXML, patchesDir: dirs.patchesDir)
    }

    public static func load(builtInXML: URL, patchesDir: URL) -> PatchStore {
        var builtIn: [Patch] = []
        if let data = try? Data(contentsOf: builtInXML), let parsed = try? PatchXML.parse(data) {
            var seen = Set<String>()
            builtIn = parsed.patches.filter { seen.insert($0.name).inserted }.map { meta in
                Patch(id: builtInPrefix + meta.name, name: meta.name, author: meta.author, note: meta.note,
                      source: .builtIn, defaultOn: meta.enabled, category: category(ofBuiltIn: meta.name))
            }
        }
        return PatchStore(builtIn: builtIn, files: externalFiles(in: patchesDir, excluding: builtInXML))
    }

    // MARK: Built-in categories (scripts/patches.py)

    public static let builtInPrefix = "builtin/"

    /// FPS_PRESETS: the patches each frame rate adds (the sprint fix goes with every rate above 60).
    public static func frameRatePatches(_ rate: FrameRate) -> [String] {
        switch rate {
        case .fps30: []
        case .fps60: ["60 FPS++"]
        case .fps90: ["90 FPS++", sprintFix]
        case .uncapped: ["Uncap FPS++", sprintFix]
        }
    }

    static let sprintFix = "Sprint Fix (High FPS)"
    /// Every name in FPS_PRESETS, in the order patches.py lists them.
    public static let frameRateNames = ["60 FPS++", "90 FPS++", "Uncap FPS++", sprintFix]

    /// EFFECTS: the patch of an effect and the effect's state in which the patch is on
    /// ("Disable DoF" is on while the effect is off). skip_intro, debug_camera and debug_menu are in
    /// patches.py's EFFECTS too, but the launcher has no switch for them: they are extras here.
    public static let effectPatches: [String: (effect: Effect, effectOn: Bool)] = [
        "Disable Chromatic Aberration": (.chromaticAberration, false),
        "Disable DoF": (.depthOfField, false),
        "Disable Motion Blur (perf increase)": (.motionBlur, false),
        "Disable SSAO": (.ambientOcclusion, false),
        "Disable AA": (.gameAntiAliasing, false),
        "Disable Dynamic Light Shadows (perf increase)": (.dynamicShadows, false),
        "Enable Screen Space Reflections (READ NOTE)": (.reflections, true),
    ]

    /// MODEL_LOD: the patch of each model detail level.
    public static let modelLODPatches: [String: Int] = [
        "Model LOD -2 (Highest)": -2, "Model LOD 1 (Lower)": 1, "Model LOD 2 (Lowest)": 2,
    ]

    /// SKIP_NETWORK_CHOICE.
    public static let networkPatch = "Skip Online/Offline Choice"
    /// patches.py adds it itself for a scene larger than 1080p, and uses RESOLUTION_TEMPLATE for
    /// the scene size: the other "Resolution Patch" entries would fight with the render size.
    static let heapPatch = "Increased Graphics Heap Sizes"
    static let resolutionPrefix = "Resolution Patch "

    public static func category(ofBuiltIn name: String) -> Patch.Category {
        if frameRateNames.contains(name) { return .frameRate }
        if effectPatches[name] != nil || modelLODPatches[name] != nil || name == heapPatch
            || name.hasPrefix(resolutionPrefix) { return .graphicsManaged }
        if name == networkPatch { return .network }
        return .extra
    }

    // MARK: Choices

    /// Whether a patch the user can switch is on in the profile: an external one by the profile's
    /// switch against the XML's default, a built-in extra when chosen.
    public static func isOn(_ patch: Patch, in profile: Profile) -> Bool {
        profile.patches[patch.id] ?? (patch.isBuiltIn ? false : patch.defaultOn)
    }

    /// The profile with one patch switched: only a difference from the default is kept.
    public static func setting(_ patch: Patch, on: Bool, in profile: Profile) -> Profile {
        var profile = profile
        let isDefault = on == (patch.isBuiltIn ? false : patch.defaultOn)
        profile.patches[patch.id] = isDefault ? nil : on
        return profile
    }

    /// Whether a frame-rate patch is on for the profile.
    public static func frameRatePatchIsOn(_ patch: Patch, in profile: Profile) -> Bool {
        frameRatePatches(profile.frameRate).contains(patch.name)
    }

    /// Whether the Graphics or Advanced page turns a managed patch on: nil when it depends on more
    /// than a switch (the render size's patches).
    public static func managedState(_ patch: Patch, profile: Profile, settings: LauncherSettings) -> Bool? {
        if let (effect, effectOn) = effectPatches[patch.name] { return profile.isOn(effect) == effectOn }
        if let level = modelLODPatches[patch.name] { return profile.modelLOD == level }
        if patch.name == networkPatch { return settings.skipNetworkChoice }
        return nil
    }

    /// Two chosen patches patches.py refuses (validate_patch_requirements).
    public static func conflict(in profile: Profile) -> (String, String)? {
        let a = builtInPrefix + "Restore Debug Camera", b = builtInPrefix + "Enemy Control"
        return profile.patches[a] == true && profile.patches[b] == true ? ("Restore Debug Camera", "Enemy Control") : nil
    }

    // MARK: Launch

    /// patches.json for the profile (patches.py external_selection): the external patches switched
    /// against their default. Sorted, so the file only changes when a choice does.
    public static func patchesJSON(for profile: Profile) -> Data {
        var enabled: [String] = [], disabled: [String] = []
        for (key, on) in profile.patches where !key.hasPrefix(builtInPrefix) {
            if on { enabled.append(key) } else { disabled.append(key) }
        }
        let object: [String: [String]] = ["enabled": enabled.sorted(), "disabled": disabled.sorted()]
        // Cannot fail: strings only.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    /// BB_PATCHES (patches.py --extra): the profile's chosen built-in extras, ";" separated. Names
    /// are in the order of the XML; without a built-in list (a missing file), in name order and
    /// unchecked, as patches.py then reports the missing file.
    public func extraNames(for profile: Profile) -> String {
        let chosen = profile.patches.filter { $0.key.hasPrefix(Self.builtInPrefix) && $0.value }
        if builtIn.isEmpty { return Self.names(chosen.keys.sorted()) }
        return Self.names(builtIn.filter { $0.category == .extra && chosen[$0.id] == true }.map(\.id))
    }

    /// The same without a list to check against.
    public static func extraNames(for profile: Profile) -> String {
        PatchStore().extraNames(for: profile)
    }

    private static func names(_ keys: [String]) -> String {
        keys.map { String($0.dropFirst(builtInPrefix.count)) }.filter { !$0.contains(";") }.joined(separator: ";")
    }

    // MARK: External files

    /// patches.py external_patches: eboot patches for app version 01.09 in directory/*.xml (sorted
    /// by name, hidden files and other extensions skipped), minus the built-in file.
    static func externalFiles(in directory: URL, excluding builtIn: URL) -> [PatchFile] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".xml") && !$0.hasPrefix(".") }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var files: [PatchFile] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if url.resolvingSymlinksInPath().path == builtIn.resolvingSymlinksInPath().path { continue }
            files.append(inspect(url))
        }
        return files
    }

    /// What patches.py would find in one XML file.
    static func inspect(_ url: URL) -> PatchFile {
        let name = url.lastPathComponent
        var file = PatchFile(name: name, url: url, patches: [], problem: nil)
        let parsed: PatchXML
        do {
            parsed = try PatchXML.parse(try Data(contentsOf: url))
        } catch {
            file.problem = .unreadable(Self.message(of: error))
            return file
        }
        if !parsed.titleIDs.isEmpty, parsed.titleIDs.isDisjoint(with: bloodborneIDs) {
            file.problem = .otherGame
            return file
        }
        var seen = Set<String>()
        for meta in parsed.patches where seen.insert(meta.name).inserted {
            file.patches.append(Patch(id: name + "/" + meta.name, name: meta.name, author: meta.author, note: meta.note,
                                      source: .external(file: name), defaultOn: meta.enabled, category: .extra))
        }
        if file.patches.isEmpty { file.problem = .noPatches }
        return file
    }

    /// patches.py BLOODBORNE_IDS.
    static let bloodborneIDs: Set<String> = ["CUSA00900", "CUSA00207", "CUSA00208", "CUSA00299", "CUSA01363",
                                             "CUSA03179", "CUSA03173", "CUSA03014", "CUSA03023"]

    private static func message(of error: Error) -> String {
        (error as NSError).localizedDescription
    }

    // MARK: Import

    public enum ImportError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case otherGame
        case noPatches

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return String(localized: "This file is not a readable patch file: \(detail)", table: "Patches", bundle: .resources)
            case .otherGame:
                return String(localized: "These patches are for another game.", table: "Patches", bundle: .resources)
            case .noPatches:
                return String(localized: "The file has no patches for Bloodborne 1.09 (eboot.bin, version 01.09).", table: "Patches", bundle: .resources)
            }
        }
    }

    /// Copies an XML patch file into the patches folder after the checks patches.py makes (it
    /// parses, its title ids include Bloodborne's, it has eboot patches for 01.09). A file of the
    /// same name is replaced. Returns the file's name (the key's prefix).
    @discardableResult
    public static func importXML(from source: URL, into dirs: DataDirs) throws -> String {
        let probe = inspect(source)
        switch probe.problem {
        case .unreadable(let detail)?: throw ImportError.unreadable(detail)
        case .otherGame?: throw ImportError.otherGame
        case .noPatches?: throw ImportError.noPatches
        case nil: break
        }
        try FileManager.default.createDirectory(at: dirs.patchesDir, withIntermediateDirectories: true)
        var name = source.lastPathComponent
        if !name.hasSuffix(".xml") { name = (name as NSString).deletingPathExtension + ".xml" }
        // No folder separator or leading dot in a name patches.py would skip.
        name = name.replacingOccurrences(of: "/", with: "-")
        if name.hasPrefix(".") { name = "patches" + name }
        let destination = dirs.patchesDir.appendingPathComponent(name)
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
        return name
    }
}

/// The parts of a patch XML file the launcher reads (the same elements patches.py reads).
struct PatchXML {
    struct Meta {
        var name: String
        var author: String
        var note: String
        var enabled: Bool
    }

    var titleIDs: Set<String> = []
    var patches: [Meta] = []

    /// `Metadata` elements for app version 01.09 and eboot.bin, with a name; the `ID` elements'
    /// text (patches.py external_patches).
    static func parse(_ data: Data, appVersion: String = "01.09") throws -> PatchXML {
        let reader = Reader(appVersion: appVersion)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return reader.result
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let appVersion: String
        var result = PatchXML()
        private var inID = false
        private var idText = ""

        init(appVersion: String) { self.appVersion = appVersion }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch element {
            case "ID":
                inID = true
                idText = ""
            case "Metadata":
                guard attributes["AppVer"] == appVersion, (attributes["AppElf"] ?? "eboot.bin") == "eboot.bin",
                      let name = attributes["Name"], !name.isEmpty else { return }
                result.patches.append(Meta(
                    name: name, author: attributes["Author"] ?? "",
                    // The notes carry a literal "\n" for a line break.
                    note: (attributes["Note"] ?? "").replacingOccurrences(of: "\\n", with: "\n"),
                    enabled: (attributes["isEnabled"] ?? "false").lowercased() == "true"))
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inID { idText += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "ID" {
                inID = false
                let id = idText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { result.titleIDs.insert(id) }
            }
        }
    }
}
