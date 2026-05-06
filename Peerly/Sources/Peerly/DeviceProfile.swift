//
//  DeviceProfile.swift
//

import Foundation

/// Hardware + OS specs for one peer. Resolved once at `PeerService` startup
/// and embedded in every `hello` so callers can make routing decisions
/// (e.g. "send heavy inference to the device with more RAM and a battery
/// that's plugged in").
public struct DeviceProfile: Codable, Hashable, Sendable {

    public enum FormFactor: String, Codable, Hashable, Sendable {
        case iPhone, iPad, mac, vision, unknown
    }

    public enum ThermalState: String, Codable, Hashable, Sendable {
        case nominal, fair, serious, critical, unknown
    }

    public struct BatteryState: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable {
            /// Couldn't read battery state.
            case unknown
            /// Device has no battery (e.g. Mac mini, Studio).
            case none
            /// Running on battery, not plugged in.
            case unplugged
            /// Plugged in and charging.
            case charging
            /// Plugged in and fully charged (or AC, no battery present that's draining).
            case full
        }

        public let status: Status
        /// 0.0–1.0 if known, nil otherwise.
        public let level: Float?

        public init(status: Status, level: Float?) {
            self.status = status
            self.level = level
        }
    }

    public let formFactor: FormFactor
    /// `sysctl hw.machine` — e.g. `Mac15,9`, `iPhone16,1`. Stable identifier
    /// you can map to a marketing name client-side if you care.
    public let modelIdentifier: String
    /// `machdep.cpu.brand_string` on macOS (e.g. `Apple M3 Max`). nil on iOS
    /// because Apple doesn't expose the chip name publicly.
    public let chip: String?
    public let cpuCores: Int
    public let memoryBytes: Int64
    public let freeDiskBytes: Int64?
    /// `iOS` / `iPadOS` / `macOS` / `visionOS`.
    public let osName: String
    /// `26.1`, `17.4.1`, etc.
    public let osVersion: String
    public let batteryState: BatteryState
    public let lowPowerMode: Bool
    public let thermalState: ThermalState

    public init(
        formFactor: FormFactor,
        modelIdentifier: String,
        chip: String?,
        cpuCores: Int,
        memoryBytes: Int64,
        freeDiskBytes: Int64?,
        osName: String,
        osVersion: String,
        batteryState: BatteryState,
        lowPowerMode: Bool,
        thermalState: ThermalState
    ) {
        self.formFactor = formFactor
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.cpuCores = cpuCores
        self.memoryBytes = memoryBytes
        self.freeDiskBytes = freeDiskBytes
        self.osName = osName
        self.osVersion = osVersion
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }
}

// MARK: - Display helpers

public extension DeviceProfile {

    /// Best-effort short label, e.g. `Apple M3 Max` on macOS or
    /// `iPhone16,1` on iOS where the chip isn't exposed.
    var processorLabel: String {
        if let chip, !chip.isEmpty { return chip }
        if !modelIdentifier.isEmpty, modelIdentifier != "arm64", modelIdentifier != "x86_64" {
            return modelIdentifier
        }
        return "Apple Silicon"
    }

    var memoryGB: Double {
        Double(memoryBytes) / 1_073_741_824
    }

    var freeDiskGB: Double? {
        guard let freeDiskBytes else { return nil }
        return Double(freeDiskBytes) / 1_073_741_824
    }

    /// One-liner for compact UI: `Apple M3 Max · 64 GB · macOS 26.1 · plugged in`.
    var summary: String {
        var parts: [String] = [processorLabel]
        parts.append(String(format: "%.0f GB", memoryGB))
        parts.append("\(osName) \(osVersion)")
        if let battery = batterySummary {
            parts.append(battery)
        }
        return parts.joined(separator: " · ")
    }

    /// Human-readable battery summary, or nil for AC-only devices we don't
    /// want to mention.
    var batterySummary: String? {
        switch batteryState.status {
        case .none, .unknown:
            return nil
        case .full:
            return "plugged in"
        case .charging:
            if let level = batteryState.level {
                return "charging \(Int((level * 100).rounded()))%"
            }
            return "charging"
        case .unplugged:
            if let level = batteryState.level {
                return "battery \(Int((level * 100).rounded()))%"
            }
            return "on battery"
        }
    }
}
