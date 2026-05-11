//
//  ServiceClient.swift
//

import Foundation

/// Typed wrapper around the raw byte transport. JSON-encodes the request,
/// JSON-decodes each chunk into `Contract.Response`. Cancellation propagates
/// when the consuming Task is cancelled — the library sends a `cancel`
/// envelope to the host so it stops generating.
@MainActor
public struct ServiceClient<Contract: ServiceContract> {
    let peerService: PeerService
    let peer: Peer

    public func stream(_ request: Contract.Request) -> AsyncThrowingStream<Contract.Response, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let payload = try JSONEncoder().encode(request)
                    let raw = peerService.requestRaw(
                        serviceID: Contract.id,
                        payload: payload,
                        on: peer
                    )
                    for try await chunkData in raw {
                        do {
                            let response = try JSONDecoder().decode(Contract.Response.self, from: chunkData)
                            continuation.yield(response)
                        } catch {
                            continuation.finish(throwing: PeerError.decode(error.localizedDescription))
                            return
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
