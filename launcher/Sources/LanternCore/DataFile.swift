// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The launcher's JSON files (games.json, launcher.json, profiles): a file that cannot be read is
/// kept aside, never overwritten by the next save.
public enum DataFile {
    /// Decodes `url`. A missing file is nil. A file that cannot be read or decoded is renamed to
    /// "<file>.unreadable-<time>" (appended to `setAside`) and nil is returned.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, setAside: inout [URL], now: Date = Date()) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder.lantern.decode(T.self, from: Data(contentsOf: url))
        } catch {
            if let moved = Self.setAside(url, now: now) { setAside.append(moved) }
            return nil
        }
    }

    /// Renames the file to "<file>.unreadable-<time>" (a unique name); nil when that fails.
    static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let base = url.path + ".unreadable-" + BackupStore.name(for: now)
        var target = URL(fileURLWithPath: base)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = URL(fileURLWithPath: base + "-\(counter)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}

/// An array element decoded on its own: a broken one is nil instead of failing the array.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// A field with a default: missing, null or unreadable (a value of a newer or older version)
    /// keeps the default, so a file from another version still loads.
    func decode<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }

    /// An optional field: missing or unreadable is nil.
    func decodeLenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
