//
//  PeerError.swift
//

import Foundation

public enum PeerError: Error, LocalizedError, Sendable {
    /// No peer is currently connected.
    case notConnected
    /// The peer asked for a service the host hasn't registered.
    case noServiceRegistered(String)
    /// The peer reported an error while running the service.
    case remote(String)
    /// Couldn't decode a response from the peer.
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to a peer."
        case .noServiceRegistered(let id):
            "No service registered for '\(id)'."
        case .remote(let message):
            message
        case .decode(let message):
            "Decoding failed: \(message)"
        }
    }
}
