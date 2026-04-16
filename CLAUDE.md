# CLAUDE.md - Macula Dist Relay

## Overview

Specialized QUIC relay for Erlang distribution over the Macula mesh. Replaces the pub/sub-based dist tunneling approach in `macula_dist_relay`/`macula_dist_bridge` (SDK) with raw QUIC stream routing.

**This is NOT a general-purpose relay.** For pub/sub, RPC, DHT routing, see `macula-io/macula-relay` (the "station"). This server handles ONLY Erlang distribution traffic between BEAM nodes that want to form a cluster over the internet.

## Architecture

### Why a separate relay for dist?

The general-purpose station handles 1000+ connected nodes with continuous heartbeat traffic. Erlang distribution has fundamentally different requirements:

| | Station (pub/sub/RPC) | Dist Relay |
|---|---|---|
| Connected nodes | 1000+ | Handful (cluster members) |
| Latency tolerance | 100ms+ | < 10ms (net_kernel ticks) |
| Ordering | Per-topic eventual | Strict per-stream FIFO |
| Framing | MessagePack messages | Raw binary bytestream |
| Encryption | Application-level | QUIC TLS 1.3 (no double encryption) |
| Session model | Stateless pub/sub | Persistent tunnels |

Forcing dist through the station's MessagePack/pub/sub pipeline added ~12 processing steps per frame, two encode/decode cycles, and scheduler competition with heartbeat floods. The dist relay reduces this to 3 steps: read from source stream, route lookup, write to dest stream.

### Connection model

Each Erlang node connects to the dist relay over QUIC. The connection has:

1. **Stream 0 (control)**: MessagePack-framed handshake and tunnel management
   - Node identifies itself: `{identify, NodeName}`
   - Request tunnel: `{tunnel, TargetNodeName}` → `{tunnel_ok, TunnelId, StreamId}`
   - Teardown: `{tunnel_close, TunnelId}`

2. **Streams 1+ (tunnels)**: raw byte forwarding, one stream per tunnel direction
   - No framing, no encoding — just the dist wire bytes
   - QUIC per-stream flow control and ordering
   - QUIC TLS 1.3 encryption (no additional AES-256-GCM needed)

### Data flow (hot path)

```
Alice dist frame
  → Alice's QUIC stream 3 (dedicated tunnel stream)
  → Dist relay reads raw bytes
  → Route table: stream 3 → Bob's stream 7
  → Dist relay writes raw bytes to Bob's stream 7
  → Bob receives raw dist bytes
```

No MessagePack. No pub/sub. No handler pipeline. No gen_tcp loopback.

## Build & Run

```bash
rebar3 get-deps
rebar3 compile
rebar3 shell
```

## Release

```bash
rebar3 as prod release
./_build/prod/rel/macula_dist_relay/bin/macula_dist_relay foreground
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MACULA_DIST_PORT` | QUIC listener port (UDP) | `4434` |
| `MACULA_TLS_CERTFILE` | TLS certificate path | via `macula_tls` |
| `MACULA_TLS_KEYFILE` | TLS private key path | via `macula_tls` |

## Module Structure

```
src/
├── macula_dist_relay_app.erl        # Application behaviour
├── macula_dist_relay_sup.erl        # Top-level supervisor
├── macula_dist_relay_listener.erl   # QUIC listener (accepts node connections)
├── macula_dist_relay_router.erl     # Route table (node → tunnel stream mapping)
├── macula_dist_relay_tunnel_sup.erl # simple_one_for_one for forwarders
└── macula_dist_relay_forwarder.erl  # Per-tunnel raw byte stream forwarder
```

## Railroad Model

In the railroad metaphor:
- **Station** (`macula-relay`): the train station — routes pub/sub messages, RPC, DHT. Handles all mesh participants.
- **Dist Relay** (this): a dedicated freight tunnel — carries raw Erlang distribution bytes between BEAM nodes. Only cluster members connect. No passenger traffic.
