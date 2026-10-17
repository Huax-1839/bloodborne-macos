// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A profile's expert variables (`Profile.environment`): which names a profile may set. One rule
/// for the Advanced page, the profile import and `LaunchSpec.make`.
public enum ExpertVariables {
    /// The prefixes the game and its libraries read (run.sh passes these on).
    public static let prefixes = ["BB_", "MVK_", "ROSETTA_"]

    /// Variables that choose the program started on Play, where the game writes its ini, or the
    /// save folders: a profile file from elsewhere never brings them along.
    public static let notImported: Set<String> = ["BB_PROBE", "BB_CONFIG", "BB_USER_DIR", "BB_GPU_USER_DIR"]

    /// A prefix and then capitals, digits and `_` (no DYLD_*, no PATH).
    public static func isValidName(_ name: String) -> Bool {
        prefixes.contains { name.hasPrefix($0) && name.count > $0.count }
            && name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }

    /// The variables with a valid name.
    public static func valid(_ environment: [String: String]) -> [String: String] {
        environment.filter { isValidName($0.key) }
    }
}
