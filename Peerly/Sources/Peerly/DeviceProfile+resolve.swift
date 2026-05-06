//
//  DeviceProfile+resolve.swift
//
//  Reads hardware + OS state via sysctl, ProcessInfo, UIDevice (iOS), and
//  IOKit power sources (macOS). Snapshot-style: call once at `PeerService`
//  startup, embed in `hello`, done. No live updates in v1.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import IOKit.ps
#endif

public extension DeviceProfile {

    @MainActor
    static func current() -> DeviceProfile {
        DeviceProfile(
            formFactor: resolveFormFactor(),
            modelIdentifier: sysctlString("hw.machine") ?? "unknown",
            chip: resolveChip(),
            cpuCores: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            freeDiskBytes: resolveFreeDisk(),
            osName: resolveOSName(),
            osVersion: resolveOSVersion(),
            batteryState: resolveBatteryState(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: resolveThermalState()
        )
    }

    // MARK: - Form factor

    @MainActor
    private static func resolveFormFactor() -> FormFactor {
        #if os(macOS)
        return .mac
        #elseif os(visionOS)
        return .vision
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return .iPad
        case .mac: return .mac
        case .vision: return .vision
        default:    return .iPhone
        }
        #else
        return .unknown
        #endif
    }

    // MARK: - Chip

    private static func resolveChip() -> String? {
        #if os(macOS)
        return sysctlString("machdep.cpu.brand_string")
        #else
        // No public API on iOS. UI falls back to model identifier.
        return nil
        #endif
    }

    // MARK: - OS

    @MainActor
    private static func resolveOSName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        return "Apple"
        #endif
    }

    private static func resolveOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion > 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    // MARK: - Disk

    private static func resolveFreeDisk() -> Int64? {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path) else {
            return nil
        }
        if let size = attrs[.systemFreeSize] as? NSNumber {
            return size.int64Value
        }
        return nil
    }

    // MARK: - Battery

    @MainActor
    private static func resolveBatteryState() -> BatteryState {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let raw = UIDevice.current.batteryLevel
        let level: Float? = raw >= 0 ? raw : nil
        let status: BatteryState.Status
        switch UIDevice.current.batteryState {
        case .charging: status = .charging
        case .full:     status = .full
        case .unplugged: status = .unplugged
        case .unknown:  status = .unknown
        @unknown default: status = .unknown
        }
        return BatteryState(status: status, level: level)
        #elseif os(macOS)
        return resolveMacBatteryState()
        #else
        return BatteryState(status: .unknown, level: nil)
        #endif
    }

    #if os(macOS)
    private static func resolveMacBatteryState() -> BatteryState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return BatteryState(status: .unknown, level: nil)
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryState(status: .none, level: nil)
        }

        for source in sources {
            guard let descRef = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue(),
                  let desc = descRef as? [String: Any]
            else { continue }
            let transport = desc[kIOPSTransportTypeKey] as? String
            guard transport == kIOPSInternalType else { continue }

            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let isCharged = desc[kIOPSIsChargedKey] as? Bool ?? false
            let powerState = desc[kIOPSPowerSourceStateKey] as? String
            let current = desc[kIOPSCurrentCapacityKey] as? Int
            let max = desc[kIOPSMaxCapacityKey] as? Int

            let level: Float?
            if let current, let max, max > 0 {
                level = Float(current) / Float(max)
            } else {
                level = nil
            }

            let status: BatteryState.Status
            if isCharged {
                status = .full
            } else if isCharging {
                status = .charging
            } else if powerState == kIOPSACPowerValue {
                status = .full
            } else {
                status = .unplugged
            }
            return BatteryState(status: status, level: level)
        }
        // No internal battery (Mac mini, Studio, Pro).
        return BatteryState(status: .none, level: nil)
    }
    #endif

    // MARK: - Thermal

    private static func resolveThermalState() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    // MARK: - sysctl helper

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Drop trailing null terminator before decoding.
        if let firstNull = buffer.firstIndex(of: 0) {
            buffer = Array(buffer[..<firstNull])
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
