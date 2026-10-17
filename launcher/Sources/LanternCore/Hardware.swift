// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import IOKit
import IOKit.ps

/// The Mac the launcher runs on (D16): chip, GPU cores, memory, and the conditions that cost
/// frame rate (battery, Low Power Mode, heat).
public struct Hardware: Equatable, Sendable {
    /// "Apple M4" (machdep.cpu.brand_string).
    public var chip: String
    /// The GPU's core count from the IORegistry (AGXAccelerator gpu-core-count), nil if unknown.
    public var gpuCores: Int?
    public var memoryGB: Int
    public var appleSilicon: Bool
    public var macOSMajor: Int

    public init(chip: String, gpuCores: Int?, memoryGB: Int, appleSilicon: Bool, macOSMajor: Int) {
        self.chip = chip
        self.gpuCores = gpuCores
        self.memoryGB = memoryGB
        self.appleSilicon = appleSilicon
        self.macOSMajor = macOSMajor
    }

    public static func current() -> Hardware {
        Hardware(chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
                 gpuCores: gpuCoreCount(),
                 memoryGB: Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30),
                 appleSilicon: MacHost.appleSilicon, macOSMajor: MacHost.macOSMajor)
    }

    /// The built-in preset for this Mac: up to 10 GPU cores the Air's (measured), up to 20 the
    /// Pro estimate, more the Max estimate.
    public var suggestedProfile: Profile {
        guard let cores = gpuCores else { return .air }
        if cores <= 10 { return .air }
        if cores <= 20 { return .pro }
        return .max
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                return value
            }
        }
        return nil
    }
}

/// What may lower the frame rate right now (the home page's warnings, D16).
public struct PowerConditions: Equatable, Sendable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    /// ProcessInfo's thermal state is serious or critical.
    public var hot: Bool

    public static func current() -> PowerConditions {
        let thermal = ProcessInfo.processInfo.thermalState
        return PowerConditions(onBattery: onBatteryPower(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                               hot: thermal == .serious || thermal == .critical)
    }

    static func onBatteryPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
