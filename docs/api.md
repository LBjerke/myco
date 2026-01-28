# API and Protocol

Two surfaces exist: a minimal HTTP-like API for metrics/deploy, and a TCP protocol with optional encryption. Both are intentionally small; payloads are binary structs, not JSON.

## HTTP-Like API (`src/api/server.zig`)
- Listener: provided by the embedding runtime (simulator/tests); `ApiServer.handleRequest` processes raw request bytes.
- Endpoints:
  - `GET /metrics`
    - Response body fields:
      - `node_id`
      - `knowledge_height` (monotonic WAL-backed counter)
      - `services_known` (count of CRDT entries)
      - `last_deployed` (last service id applied)
      - `packet_mac_failures` (drops due to failed packet auth)
  - `POST /deploy`
    - Body: raw `Service` struct (binary) with exact size `@sizeOf(Service)`:
      - `id: u64`
      - `name: [32]u8` (zero-padded)
      - `flake_uri: [128]u8`
      - `exec_name: [32]u8`
    - Success: `HTTP/1.0 200 OK` with “Deployed ID <id>”.
    - If the incoming version is not newer, response is “Already up to date”.
- Authorization:
  - If `auth_token` or `auth_token_prev` is configured, requests must include `Authorization: Bearer <token>`. Otherwise open.
- Notes:
  - The handler assumes correctly sized bodies; mismatch yields `400 Bad Request`.
  - Alignment is handled internally by copying into a local `Service` struct before applying.

## TCP Protocol (`src/net/protocol.zig`)
- Message framing:
  - Length-prefixed JSON envelope: `Packet { type: MessageType, payload: []u8 }`.
  - Types: `ListServices`, `ServiceList`, `DeployService`, `FetchService`, `ServiceConfig`, `Error`, `UploadStart`, `Gossip`, `GossipDone`.
- Security modes:
  - Plaintext or AES-GCM (`SecurityMode`), negotiated during handshake.
  - Handshake uses Ed25519 for mutual auth:
    - Server sends challenge + proof; client verifies and responds with proof and desired mode.
    - Shared key derived from server/client pubkeys; optional PSK mix.
  - Options: `allow_plaintext`, `force_plaintext`, `psk`.
- Helpers:
  - `Wire.send/receive` for plaintext messages.
  - `Wire.sendEncrypted/receiveEncrypted` for AES-GCM payloads.
  - `streamSend/streamReceive` for file streaming without loading whole payloads.
- Packet vs. Protocol:
  - The gossip CRDT path uses the 1024-byte `src/packet.zig` struct (binary, simulator-friendly).
  - The TCP protocol is a higher-level control channel and can coexist with packetized gossip.

## Packet Reference
- Packet layout and CRDT mechanics are detailed in `docs/architecture.md`. The HTTP/TCP APIs sit above that layer.
