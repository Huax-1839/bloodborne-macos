// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import LanternCore

final class HardwareTests: XCTestCase {
    func testThisMac() {
        let hardware = Hardware.current()
        XCTAssertFalse(hardware.chip.isEmpty)
        XCTAssertGreaterThan(hardware.memoryGB, 0)
        // A virtual machine (CI) has a paravirtual GPU without a core count.
        if let cores = hardware.gpuCores { XCTAssertGreaterThan(cores, 0) }
        _ = PowerConditions.current()
    }

    func testSuggestion() {
        func suggest(_ cores: Int?) -> String {
            Hardware(chip: "x", gpuCores: cores, memoryGB: 16, appleSilicon: true, macOSMajor: 27).suggestedProfile.id
        }
        XCTAssertEqual(suggest(8), Profile.air.id)
        XCTAssertEqual(suggest(10), Profile.air.id)
        XCTAssertEqual(suggest(20), Profile.pro.id)
        XCTAssertEqual(suggest(40), Profile.max.id)
        XCTAssertEqual(suggest(nil), Profile.air.id)
    }
}
