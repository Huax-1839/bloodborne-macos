// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The plain-language explanation and next step for each game check result (D6), from
/// scripts/game_check.py explain(), localised.
public enum GameCheckText {
    public static func problem(_ check: GameCheck) -> String {
        let found = String(localized: "Found \(check.title), version \(check.version).", bundle: .module)
        switch check.problem {
        case nil:
            return String(localized: "Bloodborne \(check.title) with update 1.09: ready to play.", bundle: .module)
        case .notAGame:
            return String(localized: "This folder is not a PS4 game: it has no eboot.bin and sce_sys/param.sfo. Choose the folder that contains them (for example CUSA03173).", bundle: .module)
        case .missingUpdate:
            return found + " " + String(localized: "The game needs update 1.09. Import the base game together with the 1.09 update (folder or PKG): the launcher merges them.", bundle: .module)
        case .wrongEboot:
            return found + " " + String(localized: "The game data says 1.09 but eboot.bin is from another version. Import the base game together with the full 1.09 update again.", bundle: .module)
        case .patchedEboot:
            return found + " " + String(localized: "This eboot.bin has a 60 FPS patch baked in, which crashes the game in the gestures menu. Use a clean dump of the 1.09 update; the launcher has its own frame-rate settings.", bundle: .module)
        case .otherTitle:
            return found + " " + String(localized: "This is not a retail release of Bloodborne. Any region and The Old Hunters editions work, with update 1.09.", bundle: .module)
        case .unreadable:
            return found + " " + String(localized: "eboot.bin could not be read as a decrypted PS4 executable. Dump or extract the game and the 1.09 update again. A delta update PKG does not work: a full 1.09 update is needed.", bundle: .module)
        case .damagedFiles:
            return found + " " + String(localized: "The game files are damaged: the shaders do not unpack and the game would hang while loading. The extraction tool left parts of the files stale; extract the game again with another tool.", bundle: .module)
        }
    }
}
