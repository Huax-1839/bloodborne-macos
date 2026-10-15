// SPDX-License-Identifier: GPL-2.0-or-later
// winid <owner substring>: on-screen windows of a process (id, title, bounds), for screencapture -l.
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains(CommandLine.arguments[1]) {
    print(w[kCGWindowNumber as String]!, w[kCGWindowName as String] ?? "", w[kCGWindowBounds as String]!)
}
