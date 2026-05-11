//
//  PeerEnvelope.swift
//
//  Wire v2. Payloads are opaque Data so any model type can be served — the
//  service id tells both sides how to interpret the bytes.
//

import Foundation

public enum PeerEnvelope: Codable, Sendable {
    /// Capability handshake exchanged on connect.
    case hello(HelloPayload)

    /// Client → host: please run `serviceID` with this payload.
    case request(id: UUID, serviceID: String, payload: Data)

    /// Host → client: one streamed response chunk for `id`.
    case chunk(id: UUID, payload: Data)

    /// Host → client: stream finished cleanly.
    case done(id: UUID)

    /// Either direction: stop the in-flight request `id`.
    case cancel(id: UUID)

    /// Host → client: stream failed, here's why.
    case error(id: UUID, message: String)

    private enum CodingKeys: String, CodingKey {
        case type, hello, id, serviceID, payload, message
    }

    private enum EnvelopeType: String, Codable {
        case hello, request, chunk, done, cancel, error
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let payload):
            try c.encode(EnvelopeType.hello, forKey: .type)
            try c.encode(payload, forKey: .hello)
        case .request(let id, let serviceID, let payload):
            try c.encode(EnvelopeType.request, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(serviceID, forKey: .serviceID)
            try c.encode(payload, forKey: .payload)
        case .chunk(let id, let payload):
            try c.encode(EnvelopeType.chunk, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(payload, forKey: .payload)
        case .done(let id):
            try c.encode(EnvelopeType.done, forKey: .type)
            try c.encode(id, forKey: .id)
        case .cancel(let id):
            try c.encode(EnvelopeType.cancel, forKey: .type)
            try c.encode(id, forKey: .id)
        case .error(let id, let message):
            try c.encode(EnvelopeType.error, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(EnvelopeType.self, forKey: .type)
        switch type {
        case .hello:
            self = .hello(try c.decode(HelloPayload.self, forKey: .hello))
        case .request:
            self = .request(
                id: try c.decode(UUID.self, forKey: .id),
                serviceID: try c.decode(String.self, forKey: .serviceID),
                payload: try c.decode(Data.self, forKey: .payload)
            )
        case .chunk:
            self = .chunk(
                id: try c.decode(UUID.self, forKey: .id),
                payload: try c.decode(Data.self, forKey: .payload)
            )
        case .done:
            self = .done(id: try c.decode(UUID.self, forKey: .id))
        case .cancel:
            self = .cancel(id: try c.decode(UUID.self, forKey: .id))
        case .error:
            self = .error(
                id: try c.decode(UUID.self, forKey: .id),
                message: try c.decode(String.self, forKey: .message)
            )
        }
    }
}
