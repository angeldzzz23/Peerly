//
//  Peer.swift
//

import Foundation

/// A nearby device the local peer can connect to or is connected to.
///
/// `id` is stable for the lifetime of the peer's app process — it's used as
/// the key into hello/capability dictionaries and survives reconnection within
/// the same browse cycle. `displayName` is the human-readable label.
public struct Peer: Hashable, Identifiable, Sendable {
    public typealias ID = String

    public let id: ID
    public let displayName: String

    public init(id: ID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Connection state with respect to a peer.
public enum ConnectionStatus: Hashable, Sendable {
    case notConnected
    case connecting(Peer)
    case connected(Peer)
}
