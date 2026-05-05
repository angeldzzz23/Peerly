//
//  Peerly.swift
//
//  Peerly is a transport-only library for 1:1 peer connections between
//  Apple devices on the same Wi-Fi. It handles discovery (Bonjour), the
//  pairing handshake, request/streaming-response routing, and cancel
//  propagation. It knows nothing about the *content* of a call — apps
//  plug in `Service` implementations (chat, TTS, image gen, embeddings, …)
//  and Peerly routes by service id.
//
//  Wire format: see `PeerEnvelope`. JSON-encoded envelopes carry opaque
//  Data payloads, so any model type can be served as long as both sides
//  agree on a `ServiceContract`.
//
