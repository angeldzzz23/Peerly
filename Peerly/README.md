# Peerly

A small Swift library for 1:1 peer-to-peer service calls between Apple devices on
the same Wi-Fi. Plug a typed service in on the host, call it as if it were a
local function from the client, get a streaming response back. The library
knows nothing about the *contents* of a call — chat tokens, audio bytes,
embeddings, image bytes, anything goes.

```
┌──────── Device A ────────┐                  ┌──────── Device B ────────┐
│  ChatService             │                  │                          │
│  TTSService              │ ◄─── Peerly ───► │  ServiceClient<…>        │
│  (registered)            │                  │  (calls A's services)    │
└──────────────────────────┘                  └──────────────────────────┘
        ▲                                              ▲
        │           shared on the wire:               │
        │   request / chunk / done / cancel / error   │
        │   (JSON envelopes, opaque Data payloads)    │
```

## What's in scope

- Discovery + connection management over Bonjour (via MultipeerConnectivity).
- A capability handshake (`hello`) so each side knows what services the other
  is offering, including service-supplied metadata.
- A typed request/streaming-response API. You define a `ServiceContract` once,
  then host one side and call from the other — no codec ceremony at the call
  site.
- Cancel propagation. If the consumer of a stream cancels, the host's
  generation task is cancelled too.

## What's not

- **Cross-platform.** Today the transport is MultipeerConnectivity, which is
  Apple-only. The wire format and public surface were designed so the
  transport can be swapped to `Network.framework` (Bonjour + TCP) later
  without breaking the API — see "Roadmap."
- **N peers.** 1:1 pairing only.
- **Transport encryption beyond MC's defaults.** No mutual TLS / pre-shared
  keys yet.
- **Persistence.** Hosted services see a fresh handler context per request;
  it's up to the service to maintain conversation/session state.

## Status

- Platforms: iOS 17+, macOS 14+
- Swift: 6.2 (strict concurrency, `@Observable`, `@MainActor` defaults)
- Wire protocol: v1 (single envelope schema, JSON over MC's reliable channel)
- API stability: pre-1.0, expect breaking changes

## Install

Add as a local package:

```swift
.package(path: "../Peerly")
```

Or as a remote dependency once published. The library product is `Peerly`.

You also need on the consumer app:

- `NSBonjourServices` in Info.plist listing `_gemma4._tcp` and `_gemma4._udp`
  (the service type Peerly currently uses).
- `NSLocalNetworkUsageDescription` so iOS shows the local-network prompt.
- macOS sandbox: enable both `network.client` and `network.server` (or
  the equivalent `ENABLE_INCOMING/OUTGOING_NETWORK_CONNECTIONS` build
  settings).

## Core concepts

### `Peer`

```swift
public struct Peer: Hashable, Identifiable, Sendable {
    public typealias ID = String
    public let id: ID                 // stable per session, currently == display name
    public let displayName: String
}
```

The thing you connect to. `Peer.id` is the key into `peerHellos` and the
identity used by the wire layer.

### `ServiceContract`

```swift
public protocol ServiceContract: Sendable {
    static var id: String { get }                  // e.g. "gemma.chat"
    associatedtype Request: Codable & Sendable
    associatedtype Response: Codable & Sendable
}
```

A namespace conformer (typically a caseless `enum`) that declares the wire
schema for one capability. Both host and client reference the same contract
type — they get JSON encoding/decoding for free.

### `Service`

```swift
@MainActor
public protocol Service: AnyObject {
    associatedtype Contract: ServiceContract
    var metadata: [String: String] { get }
    func handle(_ request: Contract.Request,
                context: ServiceCallContext) -> AsyncThrowingStream<Contract.Response, Error>
}
```

Server-side implementation. `metadata` shows up in the `hello` payload that
peers receive — use it for things like the loaded model id, voice name, or
device-friendly description.

### `ServiceClient<Contract>`

Returned by `peerService.client(of: Contract.self, on: peer)`. Single method:

```swift
@MainActor
public struct ServiceClient<Contract: ServiceContract> {
    public func stream(_ request: Contract.Request)
        -> AsyncThrowingStream<Contract.Response, Error>
}
```

JSON-encodes the request, dispatches it as a Peerly `request` envelope,
yields a typed response stream. Cancelling the consuming Task fires a
`cancel` envelope to the host.

## Quickstart

### 1. Define the contract

```swift
nonisolated struct ChatRequest: Codable, Sendable {
    let text: String
}
nonisolated struct ChatChunk: Codable, Sendable {
    let text: String
}
nonisolated enum ChatContract: ServiceContract {
    static let id = "gemma.chat"
    typealias Request = ChatRequest
    typealias Response = ChatChunk
}
```

(The `nonisolated` is needed when your project's default actor isolation is
`MainActor`, so the `Codable` conformance can satisfy the `Sendable`
requirement.)

### 2. Host: implement and register

```swift
@MainActor
final class GemmaChatService: Service {
    typealias Contract = ChatContract

    var metadata: [String: String] {
        ["model": "gemma-4-e4b", "description": "Gemma 4 E4B · this device"]
    }

    func handle(_ request: ChatRequest,
                context: ServiceCallContext) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for token in await runYourModel(request.text) {
                    continuation.yield(ChatChunk(text: token))
                }
                continuation.finish()
            }
        }
    }
}

let peer = PeerService()
peer.register(GemmaChatService())
```

`register` snapshots the service's metadata, refreshes the advertised TXT
record, and re-sends `hello` to any connected peer.

### 3. Client: call it

```swift
let client = peerService.client(of: ChatContract.self, on: somePeer)

for try await chunk in client.stream(ChatRequest(text: "Hello")) {
    print(chunk.text, terminator: "")
}
```

The `for try await` loop terminates on the host's `done` envelope, throws
`PeerError.remote(...)` on the host's `error`, throws `CancellationError` if
the consumer cancels.

### 4. Discovery / connection

```swift
peerService.availablePeers       // [Peer]  — populated by the browser
peerService.peerHellos[peer.id]  // HelloPayload? — what they're offering
peerService.connectedPeer        // Peer? — current 1:1 partner
peerService.connect(to: peer)
peerService.disconnect()
peerService.onPeerDisconnect = { /* clean up */ }
```

All of those are `@Observable` / `@MainActor`, so SwiftUI can read them
directly with `@Environment(PeerService.self)`.

## Wire format (v1)

Every envelope is JSON, sent on MultipeerConnectivity's reliable channel.

```jsonc
{ "type": "hello", "hello": {
    "deviceName": "Angel's Mac",
    "services": [
      { "id": "gemma.chat", "metadata": { "model": "gemma-4-e4b" } }
    ],
    "busy": false
  }
}

{ "type": "request",
  "id": "<uuid>",
  "serviceID": "gemma.chat",
  "payload": "<base64 of the JSON-encoded Request>"
}

{ "type": "chunk",
  "id": "<uuid>",
  "payload": "<base64 of the JSON-encoded Response>"
}

{ "type": "done",   "id": "<uuid>" }
{ "type": "cancel", "id": "<uuid>" }
{ "type": "error",  "id": "<uuid>", "message": "..." }
```

Discovery info (Bonjour TXT record) carries one key, `s`, whose value is a
comma-separated list of advertised service ids. That's enough for the picker
to preview offerings before connecting; full `metadata` arrives in `hello`.

## Public API

```swift
PeerService
  init(displayName: String? = nil)

  // Discovery + connection
  let myPeer: Peer
  var connectionStatus: ConnectionStatus
  var availablePeers: [Peer]
  var peerHellos: [Peer.ID: HelloPayload]
  var connectedPeer: Peer? { get }
  func connect(to peer: Peer)
  func disconnect()
  var onPeerDisconnect: (() -> Void)?

  // Service registry (host)
  func register<S: Service>(_ service: S)
  func unregister(serviceID: String)
  var registeredServiceIDs: [String] { get }
  var advertisedServices: [ServiceCapability]

  // Service calls (client)
  func client<Contract: ServiceContract>(of: Contract.Type, on peer: Peer)
      -> ServiceClient<Contract>
  func requestRaw(serviceID: String, payload: Data, on peer: Peer)
      -> AsyncThrowingStream<Data, Error>

ServiceClient<Contract>
  func stream(_ request: Contract.Request)
      -> AsyncThrowingStream<Contract.Response, Error>

PeerError
  case notConnected
  case noServiceRegistered(String)
  case remote(String)
  case decode(String)
```

## How it actually works

```
client                                               host
──────                                               ────
client.stream(req)
  │ JSON-encode → Data
  ▼
PeerService.requestRaw(serviceID, payload, on: peer)
  │ allocate UUID, store stream continuation in `clientInflight[id]`
  ▼
[ wire ]  request(id, serviceID, payload) ───────►   PeerService.handle(.request(...))
                                                       │ look up registered Service
                                                       │ spawn Task<Void, Never>, store in `serverInflight[id]`
                                                       │ JSON-decode payload → Contract.Request
                                                       │ call service.handle(...)  →  AsyncThrowingStream<Response, Error>
                                                       │ for each Response:
                                                       │   JSON-encode → Data
[ wire ]  ◄────────── chunk(id, payload)               │   send chunk envelope
   │ inflight[id]?.yield(payload)
   │ ServiceClient JSON-decodes → Contract.Response
   ▼
for try await response in client.stream(req) { … }
                                                       │ on stream end:
[ wire ]  ◄────────── done(id)                         │   send done

cancel:
  consumer Task cancelled → continuation.onTermination fires
  PeerService sends cancel(id) ──────────────────►    serverInflight.removeValue(id).cancel()
                                                       Service's handle() Task throws CancellationError
                                                       (no further chunks/done sent)

disconnect:
  PeerService fails all inflight client streams (PeerError.notConnected)
  PeerService cancels all inflight server tasks
  fires onPeerDisconnect()
```

## Roadmap

- **Cross-platform transport.** Replace MultipeerConnectivity with
  `NWBrowser` + `NWListener` + `NWConnection`. Same wire format, same public
  API. Lets the Apple side talk to an Android peer running `NsdManager` +
  raw sockets implementing the same JSON envelopes.
- **TLS.** `NWParameters.tls` with a shared PSK or mutual cert. Today we
  rely on MC's link-level encryption only.
- **N peers.** Today's `connectedPeer: Peer?` becomes `connectedPeers: [Peer]`,
  and `BackendChoice`-style consumers gain per-peer routing.
- **Auto-reconnect.** Remember the last paired `Peer.id`; re-invite when the
  browser sees them again after a transient drop.
- **Binary fast path.** Right now binary payloads (audio, images) round-trip
  through base64 in JSON — a 33% size hit. Swap to a length-prefixed binary
  frame for `chunk` envelopes when payload size is large.
- **Stable peer ids.** Currently `Peer.id == displayName`. Migrate to a
  per-install UUID published in the TXT record so two devices with the same
  name don't collide and reconnects can match by id.

## License

TBD — pick one before publishing.
