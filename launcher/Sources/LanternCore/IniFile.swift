// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// bbport.ini with BbSettings::Save's merge rules (gpu/shim/bbport_settings.cpp): keys written
/// in place, unknown lines and comments kept, new keys appended, written to <file>.tmp and
/// renamed. Task L1.2.
///
/// Reading follows BbSettings::Load (a line is `key=value`, `#` as the first character starts a
/// comment, lines without `=` are ignored, the last line of a key wins) and scripts/patches.py
/// read_settings (same rules, key and value trimmed). Differences between the readers that this
/// type does not reproduce: Load trims only the end of the line (so `  key = v` is not a known key
/// for the game, while patches.py and Save's key matching trim both sides; this type trims both,
/// as Save and patches.py do); patches.py also splits `\n`/`\r`/other Unicode line breaks.
public struct IniFile: Equatable, Sendable {
    /// The written header of an empty or missing file (as Save writes it).
    static let header = "# bbport settings (in-game menu: Insert / L3+R3)"

    /// The lines without their terminators (CRLF input arrives as LF lines, as Save rewrites it).
    private var lines: [String]

    public init(text: String) {
        // String treats "\r\n" as one Character: normalise before splitting.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
        var parts = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { part -> String in
            var line = String(part)
            while line.last == "\r" { line.removeLast() }
            return line
        }
        // "a\nb\n" ends in an empty piece that is not a line; "" has no lines at all.
        if parts.last == "" { parts.removeLast() }
        lines = parts
    }

    public init() { self.init(text: "") }

    /// The file's contents; a missing file is an empty ini.
    public static func load(_ url: URL) throws -> IniFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return IniFile()
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
        }
        return IniFile(text: text)
    }

    /// `key=value` of a line, both trimmed; nil for blank lines, comments, lines without `=` and
    /// an empty key (the cases Load and Save skip).
    private static func entry(_ line: String) -> (key: String, value: String)? {
        guard let first = line.first, first != "#", let eq = line.firstIndex(of: "=") else { return nil }
        let key = trim(line[..<eq])
        guard !key.isEmpty else { return nil }
        return (key, trim(line[line.index(after: eq)...]))
    }

    private static func trim(_ text: Substring) -> String {
        var text = text
        while let c = text.first, c == " " || c == "\t" { text.removeFirst() }
        while let c = text.last, c == " " || c == "\t" { text.removeLast() }
        return String(text)
    }

    /// The value of the last line `key=value` (key and value trimmed), nil if absent.
    public subscript(key: String) -> String? {
        let key = Self.trim(Substring(key))
        for line in lines.reversed() {
            if let e = Self.entry(line), e.key == key { return e.value }
        }
        return nil
    }

    /// Sets each key in place (its first line; later duplicates dropped, as Save does) or
    /// appends it. A header comment is written first when the ini has no lines yet.
    ///
    /// (Save itself rewrites every duplicate line with the new value instead of dropping the
    /// later ones; both give the same value to Load and patches.py.)
    public mutating func set(_ keys: [(String, String)]) {
        if lines.isEmpty && !keys.isEmpty { lines.append(Self.header) }
        for (rawKey, rawValue) in keys {
            let key = Self.trim(Substring(rawKey))
            guard !key.isEmpty else { continue }
            // A value never spans lines.
            let value = Self.trim(Substring(rawValue.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")))
            let new = "\(key)=\(value)"
            var found = false
            var kept: [String] = []
            kept.reserveCapacity(lines.count + 1)
            for line in lines {
                if let e = Self.entry(line), e.key == key {
                    if !found {
                        found = true
                        kept.append(new)
                    }
                    continue
                }
                kept.append(line)
            }
            if !found { kept.append(new) }
            lines = kept
        }
    }

    /// Removes every line of `key`.
    public mutating func remove(_ key: String) {
        let key = Self.trim(Substring(key))
        lines.removeAll { Self.entry($0)?.key == key }
    }

    /// The contents as Save writes them: LF line ends, a newline after the last line.
    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Writes atomically (<file>.tmp, then rename). Creates the parent folder.
    public func write(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.path + ".tmp"
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: temporary))
            if rename(temporary, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(atPath: temporary)
            throw error
        }
    }
}
