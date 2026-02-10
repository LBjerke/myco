# Environment Variables

If you are new to Zig or this codebase, start with `docs/zero-zig/README.md` for a guided repo tour and minimal syntax primer.

## Runtime (daemon + CLI)
- `MYCO_STATE_DIR` (default `/var/lib/myco`): base dir for identity, peers, and service configs.
- `MYCO_UDS_PATH` (default `/tmp/myco.sock`): UDS path for the API server and CLI.
- `MYCO_PORT` (default `7777`): UDP gossip port and TCP transport port.
- `MYCO_NODE_ID` (default random u16): deterministic node id; also used by `myco pubkey`.
- `MYCO_SKIP_UDP` (unset): disable the UDP gossip socket when set.
- `MYCO_POLL_MS` (default `100`): poll timeout in the daemon loop.
- `MYCO_SYNC_TICKS` (default `5`): ticks between sync/gossip sweeps.
- `MYCO_GOSSIP_FANOUT` (default `4`): peers sampled per gossip tick.
- `MYCO_SKIP_EXEC` (unset): skip Nix/systemd execution on deploy.
- `MYCO_SMOKE_SKIP_EXEC` (unset): same as `MYCO_SKIP_EXEC`, used by smoke scripts.

## Security / crypto toggles
- `MYCO_PACKET_PLAINTEXT` (unset): force plaintext UDP packets (no MAC).
- `MYCO_PACKET_ALLOW_PLAINTEXT` (unset): accept plaintext UDP packets when MAC fails.
- `MYCO_TRANSPORT_PLAINTEXT` (unset): force plaintext TCP transport.
- `MYCO_TRANSPORT_ALLOW_PLAINTEXT` (unset): allow plaintext TCP transport when secure handshake fails.

## Simulation knobs (tests/simulation.zig)
- `MYCO_MAX_BYTES_IN_FLIGHT` (scenario default): override per-scenario in-flight byte cap.
- `MYCO_SIM_VERBOSE_50`, `MYCO_SIM_VERBOSE_50_HEAVY`, `MYCO_SIM_VERBOSE_50_EXTREME`, `MYCO_SIM_VERBOSE_50_REAL` (unset): enable verbose output for those sims when set.
- `MYCO_SIM_SEED_50` (default `0x50C0FFEE`)
- `MYCO_SIM_SEED_100` (default `0x64C0FFEE`)
- `MYCO_SIM_SEED_50_HEAVY` (default `0x50DEADBE`)
- `MYCO_SIM_SEED_50_EXTREME` (default `0x50E17C0E`)
- `MYCO_SIM_SEED_50_REAL` (default `0x50A11E`)
- `MYCO_SIM_SEED_50_EDGE` (default `0x50ED9E`)
- `MYCO_SIM_SEED_256` (default `0x100C0FFEE`)
- `MYCO_RUN_1096` (unset): run the 1096-node simulation when set.
- `MYCO_SIM_SEED_1096` (default `0x112233445566`)
- `MYCO_SIM_SEED_10_DUR` (default `0x10D00`)
- `MYCO_FUZZ_RUNS` (default `1`): number of fuzz runs.
- `MYCO_FUZZ_TICKS` (default `1500`): ticks per fuzz run.
- `MYCO_FUZZ_LOSS_MIN` (default `0.0`)
- `MYCO_FUZZ_LOSS_MAX` (default `0.02`)
- `MYCO_FUZZ_CRASH_MIN` (default `0.0`)
- `MYCO_FUZZ_CRASH_MAX` (default `0.0`)
- `MYCO_FUZZ_SEED` (default `0xF00FFACE`)

## CI / smoke (ci/main.go + scripts)
- `MYCO_CI_TIMEOUT_MIN` (default `7`): overall CI timeout in minutes.
- `MYCO_POLL_MS`, `MYCO_SYNC_TICKS`: forwarded into CI containers to tune daemon timing.
- `MYCO_SMOKE_PRESET` (default `default`): cluster smoke presets (`default`, `stress`, `max`).
- `MYCO_SMOKE_NODES` (default `5`): node count for cluster smoke.
- `MYCO_SMOKE_JOBS_PER_NODE` (default `2`): services per node for cluster smoke.
- `MYCO_SMOKE_MAX_WAIT_SEC` (auto): max wait for convergence; default computed from scale.
- `MYCO_SMOKE_STATUS_TIMEOUT_SEC` (default `5`): status call timeout.
- `MYCO_SMOKE_OPTIMIZE` (default `ReleaseFast`): optimization level for smoke binary.

## Script-only / legacy
- `MYCO_NET_PREFIX` (default `10.99.0` in `scripts/cluster_smoke.sh`): docker network prefix for the podman smoke script.
- `MYCO_API_TCP_PORT` (script-only): exported by `scripts/two_nodes.sh`, not read by the binary.
- `MYCO_PACKET_KEY`, `MYCO_PACKET_EPOCH`, `MYCO_TRANSPORT_PSK` (script-only): exported by `scripts/two_nodes.sh`, not read by the binary.
