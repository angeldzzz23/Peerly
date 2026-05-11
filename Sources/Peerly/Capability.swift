//
//  Capability.swift
//

import Foundation

/// One service a peer is offering that other peers can call.
public struct ServiceCapability: Codable, Hashable, Sendable {
    public let id: String                         // e.g. "gemma.chat"
    public let metadata: [String: String]         // e.g. ["model": "gemma-4-e4b"]

    public init(id: String, metadata: [String: String] = [:]) {
        self.id = id
        self.metadata = metadata
    }
}

/// Capability snapshot a peer announces about itself, exchanged on connect
/// and re-sent whenever the registered services or busy state change.
///
/// Wire-versioned: `protocolVersion` lets future Peerly builds detect older
/// peers and degrade gracefully. `profile` is optional so a peer running a
/// pre-profile build still parses fine — its `profile` just shows up nil.
public struct HelloPayload: Codable, Hashable, Sendable {
    public static let currentProtocolVersion = 1

    public let deviceName: String
    public let services: [ServiceCapability]
    public let busy: Bool
    public let profile: DeviceProfile?
    public let protocolVersion: Int

    public init(
        deviceName: String,
        services: [ServiceCapability],
        busy: Bool = false,
        profile: DeviceProfile? = nil,
        protocolVersion: Int = HelloPayload.currentProtocolVersion
    ) {
        self.deviceName = deviceName
        self.services = services
        self.busy = busy
        self.profile = profile
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case deviceName, services, busy, profile, protocolVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        services = try c.decodeIfPresent([ServiceCapability].self, forKey: .services) ?? []
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        profile = try c.decodeIfPresent(DeviceProfile.self, forKey: .profile)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(services, forKey: .services)
        try c.encode(busy, forKey: .busy)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encode(protocolVersion, forKey: .protocolVersion)
    }
}
