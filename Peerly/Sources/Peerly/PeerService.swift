//
//  PeerService.swift
//

import Foundation
import MultipeerConnectivity
import Observation

#if canImport(UIKit)
import UIKit
#endif

/// Discovery + 1:1 connection + service-routing transport.
///
/// Hosts register `Service` instances for capabilities they offer. Clients
/// call `client(of:on:).stream(...)` to invoke a remote peer's service.
/// The library is model-agnostic — it knows about service ids and opaque
/// payloads, nothing more.
@Observable
@MainActor
public final class PeerService: NSObject {

    private static let serviceType = "gemma4"
    /// Discovery-info key listing the comma-separated service ids this peer
    /// offers. Lets the picker preview offerings before we connect.
    private static let discoveryServicesKey = "s"

    public let myPeer: Peer

    @ObservationIgnored nonisolated(unsafe) private let myMCPeerID: MCPeerID
    @ObservationIgnored nonisolated(unsafe) private let session: MCSession
    @ObservationIgnored nonisolated(unsafe) private let browser: MCNearbyServiceBrowser
    @ObservationIgnored nonisolated(unsafe) private var advertiser: MCNearbyServiceAdvertiser

    public private(set) var connectionStatus: ConnectionStatus = .notConnected
    public private(set) var availablePeers: [Peer] = []
    /// Last-known capability snapshot per peer, keyed by `Peer.id`. Populated
    /// from advertised `discoveryInfo` on first sight (services only, no
    /// metadata) and overwritten by the post-connect `hello` (full metadata).
    public private(set) var peerHellos: [Peer.ID: HelloPayload] = [:]
    /// What this device is currently advertising — service id + metadata.
    /// Mirrors the `services` array sent in our outgoing `hello`, kept
    /// observable so the UI can render "what models are loaded here."
    public private(set) var advertisedServices: [ServiceCapability] = []

    /// Fired when a peer disappears (manual disconnect or peer drop). Lets
    /// app-level code reset state.
    @ObservationIgnored
    public var onPeerDisconnect: (() -> Void)?

    // MARK: - Private state

    /// MCPeerID instances keyed by Peer.id — needed because MultipeerConnectivity
    /// matches on identity, not displayName.
    @ObservationIgnored
    private var mcPeerIDs: [Peer.ID: MCPeerID] = [:]

    /// Registered server-side services keyed by service id.
    @ObservationIgnored
    private var services: [String: RegisteredService] = [:]

    /// Client-side in-flight requests: id → stream continuation.
    @ObservationIgnored
    private var clientInflight: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    /// Server-side in-flight tasks: id → task running the service.
    @ObservationIgnored
    private var serverInflight: [UUID: Task<Void, Never>] = [:]

    // MARK: - Init

    public init(displayName: String? = nil) {
        let resolvedName: String
        #if os(macOS)
        resolvedName = displayName ?? Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        resolvedName = displayName ?? UIDevice.current.name
        #else
        resolvedName = displayName ?? "Peer"
        #endif

        let mcID = MCPeerID(displayName: resolvedName)
        self.myMCPeerID = mcID
        self.myPeer = Peer(id: resolvedName, displayName: resolvedName)

        session = MCSession(peer: mcID, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: mcID, serviceType: Self.serviceType)
        advertiser = MCNearbyServiceAdvertiser(peer: mcID, discoveryInfo: nil, serviceType: Self.serviceType)

        super.init()

        session.delegate = self
        browser.delegate = self
        advertiser.delegate = self

        browser.startBrowsingForPeers()
        advertiser.startAdvertisingPeer()
    }

    // MARK: - Service registration

    /// Register a service implementation. Republishes the advertisement so
    /// nearby peers see the new capability.
    public func register<S: Service>(_ service: S) {
        let id = S.Contract.id
        services[id] = RegisteredService.from(service)
        refreshAdvertisedServices()
        republishAdvertisement()
        sendHelloToConnectedPeer()
    }

    /// Remove a previously-registered service.
    public func unregister(serviceID: String) {
        services.removeValue(forKey: serviceID)
        refreshAdvertisedServices()
        republishAdvertisement()
        sendHelloToConnectedPeer()
    }

    private func refreshAdvertisedServices() {
        advertisedServices = services.values
            .map { ServiceCapability(id: $0.id, metadata: $0.metadata) }
            .sorted(by: { $0.id < $1.id })
    }

    /// Service ids this device currently offers, for advertising.
    public var registeredServiceIDs: [String] {
        Array(services.keys).sorted()
    }

    // MARK: - Connection management

    public var connectedPeer: Peer? {
        if case .connected(let peer) = connectionStatus { return peer }
        return nil
    }

    public func connect(to peer: Peer) {
        guard let mcID = mcPeerIDs[peer.id] else {
            print("PeerService: connect — unknown peer \(peer.displayName)")
            return
        }
        connectionStatus = .connecting(peer)
        browser.invitePeer(mcID, to: session, withContext: nil, timeout: 30)
    }

    public func disconnect() {
        session.disconnect()
        connectionStatus = .notConnected
        failAllClientInflight()
        cancelAllServerInflight()
        onPeerDisconnect?()
    }

    // MARK: - Typed client

    public func client<Contract: ServiceContract>(
        of contract: Contract.Type,
        on peer: Peer
    ) -> ServiceClient<Contract> {
        ServiceClient<Contract>(peerService: self, peer: peer)
    }

    // MARK: - Raw client

    /// Low-level: send a raw payload to a peer's service and stream raw bytes
    /// back. `ServiceClient` is the typed sugar over this.
    public func requestRaw(
        serviceID: String,
        payload: Data,
        on peer: Peer
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard connectedPeer == peer else {
                print("PeerService: requestRaw — not connected to \(peer.displayName)")
                continuation.finish(throwing: PeerError.notConnected)
                return
            }
            let id = UUID()
            let shortID = id.uuidString.prefix(8)
            clientInflight[id] = continuation
            print("PeerService: → request id=\(shortID) service=\(serviceID) to=\(peer.displayName) bytes=\(payload.count)")
            sendEnvelope(.request(id: id, serviceID: serviceID, payload: payload), to: peer)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.clientInflight.removeValue(forKey: id) != nil,
                       let p = self.connectedPeer {
                        print("PeerService: → cancel id=\(shortID) to=\(p.displayName)")
                        self.sendEnvelope(.cancel(id: id), to: p)
                    }
                }
            }
        }
    }

    // MARK: - Internals

    private func currentHello(busy: Bool = false) -> HelloPayload {
        HelloPayload(deviceName: myPeer.displayName, services: advertisedServices, busy: busy)
    }

    private func republishAdvertisement() {
        advertiser.stopAdvertisingPeer()
        let info: [String: String]?
        if services.isEmpty {
            info = nil
        } else {
            info = [Self.discoveryServicesKey: services.keys.sorted().joined(separator: ",")]
        }
        // Reuse the same MCPeerID the session was created with — recreating
        // the advertiser with a fresh MCPeerID makes invitations land on a
        // different identity than the session, breaking the handshake.
        advertiser = MCNearbyServiceAdvertiser(peer: myMCPeerID, discoveryInfo: info, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
    }

    private func sendHelloToConnectedPeer() {
        guard let peer = connectedPeer else { return }
        sendEnvelope(.hello(currentHello()), to: peer)
    }

    private func sendEnvelope(_ envelope: PeerEnvelope, to peer: Peer) {
        guard let mcID = mcPeerIDs[peer.id] else { return }
        sendEnvelope(envelope, toMC: [mcID])
    }

    private func sendEnvelope(_ envelope: PeerEnvelope, toMC peers: [MCPeerID]) {
        guard !peers.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(envelope)
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            print("PeerService: send failed: \(error.localizedDescription)")
        }
    }

    private func failAllClientInflight() {
        let entries = clientInflight
        clientInflight.removeAll()
        for cont in entries.values {
            cont.finish(throwing: PeerError.notConnected)
        }
    }

    private func cancelAllServerInflight() {
        for task in serverInflight.values { task.cancel() }
        serverInflight.removeAll()
    }

    fileprivate func handle(_ envelope: PeerEnvelope, from peer: Peer) {
        switch envelope {
        case .hello(let payload):
            print("PeerService: ← hello from=\(peer.displayName) services=\(payload.services.map(\.id))")
            peerHellos[peer.id] = payload

        case .request(let id, let serviceID, let payload):
            let shortID = id.uuidString.prefix(8)
            print("PeerService: ← request id=\(shortID) service=\(serviceID) from=\(peer.displayName) bytes=\(payload.count)")
            handleIncomingRequest(id: id, serviceID: serviceID, payload: payload, from: peer)

        case .chunk(let id, let payload):
            let shortID = id.uuidString.prefix(8)
            print("PeerService: ← chunk id=\(shortID) bytes=\(payload.count)")
            clientInflight[id]?.yield(payload)

        case .done(let id):
            print("PeerService: ← done id=\(id.uuidString.prefix(8))")
            clientInflight.removeValue(forKey: id)?.finish()

        case .cancel(let id):
            print("PeerService: ← cancel id=\(id.uuidString.prefix(8)) from=\(peer.displayName)")
            serverInflight.removeValue(forKey: id)?.cancel()

        case .error(let id, let message):
            print("PeerService: ← error id=\(id.uuidString.prefix(8)) msg='\(message)'")
            clientInflight.removeValue(forKey: id)?.finish(throwing: PeerError.remote(message))
        }
    }

    private func handleIncomingRequest(id: UUID, serviceID: String, payload: Data, from peer: Peer) {
        guard let service = services[serviceID] else {
            sendEnvelope(.error(id: id, message: "No service '\(serviceID)' on host."), to: peer)
            return
        }
        let context = ServiceCallContext(peer: peer, requestID: id)
        serverInflight[id] = Task { [weak self] in
            guard let self else { return }
            let stream = service.handler(payload, context)
            do {
                for try await chunk in stream {
                    self.sendEnvelope(.chunk(id: id, payload: chunk), to: peer)
                }
                self.sendEnvelope(.done(id: id), to: peer)
            } catch is CancellationError {
                // Client cancelled — nothing more to send.
            } catch {
                self.sendEnvelope(.error(id: id, message: error.localizedDescription), to: peer)
            }
            self.serverInflight.removeValue(forKey: id)
        }
    }
}

// MARK: - Internal: Sendable wrapper for MCPeerID

/// MultipeerConnectivity types aren't `Sendable`-annotated, but MCPeerID
/// instances are immutable from the user's perspective. Wrap them in an
/// `@unchecked Sendable` box so we can hand them across the actor boundary
/// from nonisolated delegate callbacks into our @MainActor body.
private struct SendableMCPeerID: @unchecked Sendable {
    let value: MCPeerID
    init(_ value: MCPeerID) { self.value = value }
}

// MARK: - Internal: type-erased registered service

@MainActor
struct RegisteredService {
    let id: String
    let metadata: [String: String]
    let handler: @MainActor (Data, ServiceCallContext) -> AsyncThrowingStream<Data, Error>

    static func from<S: Service>(_ service: S) -> RegisteredService {
        let id = S.Contract.id
        let metadata = service.metadata
        return RegisteredService(
            id: id,
            metadata: metadata,
            handler: { [weak service] payload, context in
                AsyncThrowingStream { continuation in
                    let task = Task { @MainActor in
                        guard let service else {
                            continuation.finish(throwing: PeerError.noServiceRegistered(id))
                            return
                        }
                        do {
                            let request = try JSONDecoder().decode(S.Contract.Request.self, from: payload)
                            for try await response in service.handle(request, context: context) {
                                let data = try JSONEncoder().encode(response)
                                continuation.yield(data)
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
        )
    }
}

// MARK: - MCSessionDelegate

extension PeerService: MCSessionDelegate {

    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let displayName = peerID.displayName
        let wrapped = SendableMCPeerID(peerID)
        Task { @MainActor in
            self.mcPeerIDs[displayName] = wrapped.value
            let peer = Peer(id: displayName, displayName: displayName)
            switch state {
            case .connected:
                print("PeerService: peer connected — \(displayName)")
                self.connectionStatus = .connected(peer)
                self.availablePeers.removeAll { $0.id == peer.id }
                self.sendEnvelope(.hello(self.currentHello()), to: peer)
            case .connecting:
                print("PeerService: peer connecting — \(displayName)")
                self.connectionStatus = .connecting(peer)
            case .notConnected:
                print("PeerService: peer disconnected — \(displayName)")
                self.peerHellos[peer.id] = nil
                if self.activePeerID == peer.id {
                    self.connectionStatus = .notConnected
                    self.failAllClientInflight()
                    self.cancelAllServerInflight()
                    self.onPeerDisconnect?()
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let displayName = peerID.displayName
        do {
            let envelope = try JSONDecoder().decode(PeerEnvelope.self, from: data)
            Task { @MainActor in
                let peer = Peer(id: displayName, displayName: displayName)
                self.handle(envelope, from: peer)
            }
        } catch {
            print("PeerService: decode failed: \(error.localizedDescription)")
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private extension PeerService {
    var activePeerID: Peer.ID? {
        switch connectionStatus {
        case .connecting(let p), .connected(let p): return p.id
        case .notConnected: return nil
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerService: MCNearbyServiceBrowserDelegate {

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let displayName = peerID.displayName
        let advertisedServices = (info?["s"] ?? "")
            .split(separator: ",")
            .map(String.init)
        let wrapped = SendableMCPeerID(peerID)
        Task { @MainActor in
            self.mcPeerIDs[displayName] = wrapped.value
            let peer = Peer(id: displayName, displayName: displayName)
            if !self.availablePeers.contains(where: { $0.id == peer.id }) && self.activePeerID != peer.id {
                self.availablePeers.append(peer)
            }
            // Stash a partial hello so the picker can preview offered services
            // before we connect.
            if self.peerHellos[peer.id] == nil {
                let caps = advertisedServices.map { ServiceCapability(id: $0) }
                self.peerHellos[peer.id] = HelloPayload(
                    deviceName: peer.displayName,
                    services: caps,
                    busy: false
                )
            }
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let displayName = peerID.displayName
        Task { @MainActor in
            self.availablePeers.removeAll { $0.id == displayName }
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerService: MCNearbyServiceAdvertiserDelegate {

    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 1:1 pairing: accept only if no one is connected yet.
        let accept = session.connectedPeers.isEmpty
        invitationHandler(accept, accept ? session : nil)
    }
}
