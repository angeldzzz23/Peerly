//
//  Service.swift
//

import Foundation

/// Schema for a service: its id and its request/response types. Shared by
/// both the host (to implement `Service`) and the client (to look up a
/// `ServiceClient`). Conform with a caseless enum that acts as a namespace:
///
/// ```swift
/// enum ChatContract: ServiceContract {
///     static let id = "gemma.chat"
///     typealias Request = ChatRequest
///     typealias Response = ChatChunk
/// }
/// ```
public protocol ServiceContract: Sendable {
    static var id: String { get }
    associatedtype Request: Codable & Sendable
    associatedtype Response: Codable & Sendable
}

/// Per-call context the library hands a service when a peer invokes it.
public struct ServiceCallContext: Sendable {
    public let peer: Peer
    public let requestID: UUID
}

/// Server-side implementation of a service. The associated `Contract` ties
/// it to a wire schema; `handle` runs the model and yields responses.
@MainActor
public protocol Service: AnyObject {
    associatedtype Contract: ServiceContract

    /// Free-form metadata advertised to peers in `hello`. Use for things like
    /// the loaded model id, voice name, or capabilities — anything callers
    /// might want before invoking. Empty by default.
    var metadata: [String: String] { get }

    func handle(
        _ request: Contract.Request,
        context: ServiceCallContext
    ) -> AsyncThrowingStream<Contract.Response, Error>
}

extension Service {
    public var metadata: [String: String] { [:] }
}
