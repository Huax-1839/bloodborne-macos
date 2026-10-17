// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// bbport.ini with BbSettings::Save's merge rules (gpu/shim/bbport_settings.cpp): keys written
/// in place, unknown lines and comments kept, new keys appended, written to <file>.tmp and
/// renamed. Task L1.2.
public struct IniFile: Equatable, Sendable {
    public init(text: String) { fatalError("L1.2") }
    public init() { self.init(text: "") }
    /// The file's contents; a missing file is an empty ini.
    public static func load(_ url: URL) throws -> IniFile { fatalError("L1.2") }
    /// The value of the last line `key=value` (key and value trimmed), nil if absent.
    public subscript(key: String) -> String? { fatalError("L1.2") }
    /// Sets each key in place (its first line; later duplicates dropped, as Save does) or
    /// appends it.
    public mutating func set(_ keys: [(String, String)]) { fatalError("L1.2") }
    public var text: String { fatalError("L1.2") }
    /// Writes atomically (<file>.tmp, then rename).
    public func write(to url: URL) throws { fatalError("L1.2") }
}
