//
//  PeerService.swift
//

import Foundation
import MultipeerConnectivity
import Observation

#if canImport(UIKit)
import UIKit
#endif

/// Discovery + N-peer connection + service-routing transport.
///
/// Each peer pairing gets its own `MCSession`, so disconnecting one peer
/// doesn't affect the others. Hosts register `Service` instances for
/// capabilities they offer; clients call `client(of:on:).stream(...)` to
/// invoke a remote peer's service. The library is model-agnostic — it
/// knows about service ids and opaque payloads, nothing more.
@Observable
@MainActor
public final class PeerService: NSObject {

    private static let serviceType = "gemma4"
    /// Discovery-info key listing the comma-separated service ids this peer
    /// offers. Lets the picker preview offerings before we connect.
    private static let discoveryServicesKey = "s"

    public let myPeer: Peer
    /// Hardware + OS specs for this device. Resolved once at init and
    /// embedded in every outgoing `hello`.
    public let myProfile: DeviceProfile

    @ObservationIgnored nonisolated(unsafe) private let myMCPeerID: MCPeerID
    @ObservationIgnored nonisolated(unsafe) private let browser: MCNearbyServiceBrowser
    @ObservationIgnored nonisolated(unsafe) private var advertiser: MCNearbyServiceAdvertiser

    /// One MCSession per peer pairing. Keyed by `Peer.id` (currently the
    /// peer's display name). Lifecycle: created on outgoing `connect(to:)`
    /// or incoming invitation, destroyed when the session goes
    /// `.notConnected`.
    @ObservationIgnored
    private var sessions: [Peer.ID: MCSession] = [:]

    public private(set) var connectedPeers: [Peer] = []
    public private(set) var connectingPeers: Set<Peer.ID> = []
    public private(set) var availablePeers: [Peer] = []
    /// Last-known capability snapshot per peer. Populated from
    /// `discoveryInfo` on first sight (services only) and overwritten by
    /// the post-connect `hello` (full metadata).
    public private(set) var peerHellos: [Peer.ID: HelloPayload] = [:]
    /// What this device is currently advertising — service id + metadata.
    /// Mirrors the `services` array sent in our outgoing `hello`.
    public private(set) var advertisedServices: [ServiceCapability] = []

    /// Fired when a specific peer disappears. Lets app-level code reset
    /// state pointing at that peer (e.g., `BackendChoice.remote(peer)` →
    /// `.local`).
    @ObservationIgnored
    public var onPeerDisconnect: ((Peer) -> Void)?

    @ObservationIgnored
    private var mcPeerIDs: [Peer.ID: MCPeerID] = [:]

    @ObservationIgnored
    private var services: [String: RegisteredService] = [:]

    /// Client-side in-flight requests. Each tracks which peer it's bound to
    /// so we can fail just that peer's requests on per-peer disconnect.
    @ObservationIgnored
    private var clientInflight: [UUID: ClientRequest] = [:]

    /// Server-side in-flight tasks. Each tracks which peer originated the
    /// request so we can cancel just that peer's tasks on per-peer
    /// disconnect.
    @ObservationIgnored
    private var serverInflight: [UUID: ServerRequest] = [:]

    private struct ClientRequest {
        let peerID: Peer.ID
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
    }

    private struct ServerRequest {
        let peerID: Peer.ID
        let task: Task<Void, Never>
    }

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
        self.myProfile = DeviceProfile.current()

        browser = MCNearbyServiceBrowser(peer: mcID, serviceType: Self.serviceType)
        advertiser = MCNearbyServiceAdvertiser(peer: mcID, discoveryInfo: nil, serviceType: Self.serviceType)

        super.init()

        browser.delegate = self
        advertiser.delegate = self

        browser.startBrowsingForPeers()
        advertiser.startAdvertisingPeer()
    }

    // MARK: - Service registration

    public func register<S: Service>(_ service: S) {
        let id = S.Contract.id
        services[id] = RegisteredService.from(service)
        refreshAdvertisedServices()
        republishAdvertisement()
        sendHelloToConnectedPeers()
    }

    public func unregister(serviceID: String) {
        services.removeValue(forKey: serviceID)
        refreshAdvertisedServices()
        republishAdvertisement()
        sendHelloToConnectedPeers()
    }

    private func refreshAdvertisedServices() {
        advertisedServices = services.values
            .map { ServiceCapability(id: $0.id, metadata: $0.metadata) }
            .sorted(by: { $0.id < $1.id })
    }

    public var registeredServiceIDs: [String] {
        Array(services.keys).sorted()
    }

    // MARK: - Connection management

    /// State for one specific peer.
    public func connectionState(for peer: Peer) -> PeerConnectionState {
        if connectedPeers.contains(where: { $0.id == peer.id }) { return .connected }
        if connectingPeers.contains(peer.id) { return .connecting }
        return .notConnected
    }

    /// True if at least one peer is currently connected.
    public var hasAnyConnection: Bool { !connectedPeers.isEmpty }

    public func connect(to peer: Peer) {
        guard let mcID = mcPeerIDs[peer.id] else {
            print("PeerService: connect — unknown peer \(peer.displayName)")
            return
        }
        let session = ensureSession(for: peer.id)
        connectingPeers.insert(peer.id)
        browser.invitePeer(mcID, to: session, withContext: nil, timeout: 30)
    }

    /// Drop the pairing with one specific peer. Other peers stay connected.
    public func disconnect(peer: Peer) {
        sessions[peer.id]?.disconnect()
        // Cleanup happens in the `.notConnected` delegate callback.
    }

    /// Drop pairings with every connected peer at once.
    public func disconnectAll() {
        for session in sessions.values {
            session.disconnect()
        }
    }

    private func ensureSession(for peerID: Peer.ID) -> MCSession {
        if let existing = sessions[peerID] { return existing }
        let session = MCSession(
            peer: myMCPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        sessions[peerID] = session
        return session
    }

    // MARK: - Typed client

    public func client<Contract: ServiceContract>(
        of contract: Contract.Type,
        on peer: Peer
    ) -> ServiceClient<Contract> {
        ServiceClient<Contract>(peerService: self, peer: peer)
    }

    // MARK: - Raw client

    public func requestRaw(
        serviceID: String,
        payload: Data,
        on peer: Peer
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard self.connectionState(for: peer) == .connected else {
                print("PeerService: requestRaw — not connected to \(peer.displayName)")
                continuation.finish(throwing: PeerError.notConnected)
                return
            }
            let id = UUID()
            let shortID = id.uuidString.prefix(8)
            clientInflight[id] = ClientRequest(peerID: peer.id, continuation: continuation)
            print("PeerService: → request id=\(shortID) service=\(serviceID) to=\(peer.displayName) bytes=\(payload.count)")
            sendEnvelope(.request(id: id, serviceID: serviceID, payload: payload), to: peer)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.clientInflight.removeValue(forKey: id) != nil {
                        print("PeerService: → cancel id=\(shortID) to=\(peer.displayName)")
                        self.sendEnvelope(.cancel(id: id), to: peer)
                    }
                }
            }
        }
    }

    // MARK: - Internals

    private func currentHello(busy: Bool = false) -> HelloPayload {
        HelloPayload(
            deviceName: myPeer.displayName,
            services: advertisedServices,
            busy: busy,
            profile: myProfile
        )
    }

    private func republishAdvertisement() {
        advertiser.stopAdvertisingPeer()
        let info: [String: String]?
        if services.isEmpty {
            info = nil
        } else {
            info = [Self.discoveryServicesKey: services.keys.sorted().joined(separator: ",")]
        }
        advertiser = MCNearbyServiceAdvertiser(
            peer: myMCPeerID,
            discoveryInfo: info,
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
    }

    private func sendHelloToConnectedPeers() {
        let hello = currentHello()
        for peer in connectedPeers {
            sendEnvelope(.hello(hello), to: peer)
        }
    }

    private func sendEnvelope(_ envelope: PeerEnvelope, to peer: Peer) {
        guard let mcID = mcPeerIDs[peer.id], let session = sessions[peer.id] else { return }
        do {
            let data = try JSONEncoder().encode(envelope)
            try session.send(data, toPeers: [mcID], with: .reliable)
        } catch {
            print("PeerService: send failed: \(error.localizedDescription)")
        }
    }

    private func failClientInflight(forPeer peerID: Peer.ID) {
        let toFail = clientInflight.filter { $0.value.peerID == peerID }
        for (id, _) in toFail {
            clientInflight.removeValue(forKey: id)
        }
        for (_, req) in toFail {
            req.continuation.finish(throwing: PeerError.notConnected)
        }
    }

    private func cancelServerInflight(forPeer peerID: Peer.ID) {
        let toCancel = serverInflight.filter { $0.value.peerID == peerID }
        for (id, _) in toCancel {
            serverInflight.removeValue(forKey: id)
        }
        for (_, req) in toCancel {
            req.task.cancel()
        }
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
            clientInflight[id]?.continuation.yield(payload)

        case .done(let id):
            print("PeerService: ← done id=\(id.uuidString.prefix(8))")
            if let req = clientInflight.removeValue(forKey: id) {
                req.continuation.finish()
            }

        case .cancel(let id):
            print("PeerService: ← cancel id=\(id.uuidString.prefix(8)) from=\(peer.displayName)")
            if let req = serverInflight.removeValue(forKey: id) {
                req.task.cancel()
            }

        case .error(let id, let message):
            print("PeerService: ← error id=\(id.uuidString.prefix(8)) msg='\(message)'")
            if let req = clientInflight.removeValue(forKey: id) {
                req.continuation.finish(throwing: PeerError.remote(message))
            }
        }
    }

    private func handleIncomingRequest(id: UUID, serviceID: String, payload: Data, from peer: Peer) {
        guard let service = services[serviceID] else {
            sendEnvelope(.error(id: id, message: "No service '\(serviceID)' on host."), to: peer)
            return
        }
        let context = ServiceCallContext(peer: peer, requestID: id)
        let task = Task { [weak self] in
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
        serverInflight[id] = ServerRequest(peerID: peer.id, task: task)
    }
}

// MARK: - Internal: Sendable wrappers for MultipeerConnectivity types

/// MultipeerConnectivity types aren't `Sendable`-annotated, but we only
/// pass them across the actor boundary in immutable ways.
private struct SendableMCPeerID: @unchecked Sendable {
    let value: MCPeerID
    init(_ value: MCPeerID) { self.value = value }
}

private struct SendableMCSession: @unchecked Sendable {
    let value: MCSession
    init(_ value: MCSession) { self.value = value }
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
                self.connectingPeers.remove(displayName)
                if !self.connectedPeers.contains(where: { $0.id == displayName }) {
                    self.connectedPeers.append(peer)
                }
                self.availablePeers.removeAll { $0.id == displayName }
                self.sendEnvelope(.hello(self.currentHello()), to: peer)
            case .connecting:
                print("PeerService: peer connecting — \(displayName)")
                self.connectingPeers.insert(displayName)
            case .notConnected:
                print("PeerService: peer disconnected — \(displayName)")
                let wasKnown = self.connectedPeers.contains(where: { $0.id == displayName })
                    || self.connectingPeers.contains(displayName)
                self.connectingPeers.remove(displayName)
                self.connectedPeers.removeAll { $0.id == displayName }
                self.peerHellos[displayName] = nil
                self.failClientInflight(forPeer: displayName)
                self.cancelServerInflight(forPeer: displayName)
                self.sessions.removeValue(forKey: displayName)
                if wasKnown {
                    self.onPeerDisconnect?(peer)
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
            let alreadyKnown = self.connectedPeers.contains(where: { $0.id == peer.id })
                || self.connectingPeers.contains(peer.id)
            if !self.availablePeers.contains(where: { $0.id == peer.id }) && !alreadyKnown {
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
        // Multi-peer: accept everyone. Each invitation gets its own MCSession,
        // so disconnecting one peer doesn't drop the others.
        let displayName = peerID.displayName
        let session = MCSession(
            peer: myMCPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        let wrappedPeer = SendableMCPeerID(peerID)
        let wrappedSession = SendableMCSession(session)
        Task { @MainActor in
            self.mcPeerIDs[displayName] = wrappedPeer.value
            self.sessions[displayName] = wrappedSession.value
        }
        invitationHandler(true, session)
    }
}
