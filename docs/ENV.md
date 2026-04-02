# Environment Variables

> **Status**: This document lists planned environment variables. Currently, only `MYCO_WAL_PATH` is implemented.

## Implemented

| Variable | Default | Description |
|----------|---------|-------------|
| `MYCO_WAL_PATH` | `data/wal/` | WAL directory path |

## Planned (Not Yet Implemented)

### Runtime (daemon)
- `MYCO_STATE_DIR` (default `/var/lib/myco`): base dir for identity, peers, and service configs.
- `MYCO_UDS_PATH` (default `/tmp/myco.sock`): UDS path for the API server and CLI.
- `MYCO_PORT` (default `7777`): UDP gossip port and TCP transport port.
- `MYCO_NODE_ID` (default random u16): deterministic node id.
- `MYCO_POLL_MS` (default `100`): poll timeout in the daemon loop.
- `MYCO_SYNC_TICKS` (default `5`): ticks between sync/gossip sweeps.
- `MYCO_GOSSIP_FANOUT` (default `4`): peers sampled per gossip tick.

### Simulation knobs (tests/simulation.zig)
- `MYCO_SIM_VERBOSE_50` (unset): enable verbose output for 50-node sim.
- `MYCO_SIM_SEED_50` (default `0x50C0FFEE`): seed for 50-node simulation.

### Security / crypto (planned)
- `MYCO_PACKET_KEY`: secret for packet encryption.
- `MYCO_PACKET_EPOCH`: epoch for the current key.
- `MYCO_PACKET_PLAINTEXT`: force plaintext packets.
