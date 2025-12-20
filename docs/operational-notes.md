# Operational Notes

Guidelines for safe changes, compatibility, and knobs to tune.

## Compatibility and Invariants
- Packet size: `src/packet.zig` must stay exactly 1024 bytes (compile-time check). Adjusting fields requires coordinated versioning and backward compatibility.
- Service payload size: `src/schema/service.zig` must stay ≤ 920 bytes to fit inside the packet payload (compile-time check).
- CRDT semantics: last-write-wins via Hybrid Logical Clocks; do not compare wall clocks directly or strip logical counters.
- WAL layout: `src/db/wal.zig` appends fixed `Entry { crc: u32, value: u64 }`. Changing layout or checksum requires a migration path or versioned WAL.
- Digest encoding: `encodeDigest/decodeDigest` use varints; altering ordering or count header breaks interoperability with existing nodes.

## Packet Crypto and Rotation
- Environment variables:
  - `MYCO_PACKET_KEY` (current secret, required for sealing/opening when crypto is enabled).
  - `MYCO_PACKET_EPOCH` (u32 epoch for the current key, also encoded into the nonce).
  - `MYCO_PACKET_KEY_PREV` / `MYCO_PACKET_EPOCH_PREV` (optional previous key for rotation).
  - `MYCO_GOSSIP_PSK` (optional PSK mixed into key derivation).
- Rotation approach:
  1) Set both current and previous keys/epochs across the fleet.
  2) Once all nodes see the new key, drop the previous key/epoch.
- Associated data binds header fields (magic, version, msg_type, node_id, zone_id, flags, revocation_block, payload_len, sender_pubkey); modifying these without updating AD rules breaks authentication.

## Gossip/CRDT Behavior Knobs
- `MYCO_GOSSIP_FANOUT`: rumor fanout (default 4) for forwarding Deploy packets.
- Sync cadence:
  - Delta digest sent when dirty.
  - Sample digest every 50 ticks when idle (reservoir sampling of state).
  - Control message every 10 ticks with optional delta digest.
- Miss handling:
  - Up to 1024 missing ids tracked; random replacement on overflow.
  - Up to 64 requests drained per tick to pull missing services.

## Operational Footnotes
- Packet plaintext: set `MYCO_PACKET_PLAINTEXT=1` where the transport supports it (for debugging).
- Metrics: `/metrics` HTTP endpoint exposes node id, knowledge height, service count, last deployed id, and packet MAC failures (see `docs/api.md`).
- Deterministic identity: `Identity.initDeterministic(id)` ties node keys to numeric ids in simulations; changing seeding affects test reproducibility.
