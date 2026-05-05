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
public struct HelloPayload: Codable, Hashable, Sendable {
    public let deviceName: String
    public let services: [ServiceCapability]
    public let busy: Bool

    public init(deviceName: String, services: [ServiceCapability], busy: Bool = false) {
        self.deviceName = deviceName
        self.services = services
        self.busy = busy
    }
}
