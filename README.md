# macula-dist-relay

Specialized QUIC relay for Erlang distribution over the [Macula](https://hex.pm/packages/macula) mesh.

Routes raw distribution bytes between BEAM nodes via dedicated QUIC streams — no pub/sub overhead, no MessagePack framing, no double encryption.

## Why?

Erlang distribution needs low-latency, ordered byte streams. The general-purpose Macula relay routes pub/sub and RPC through a MessagePack handler pipeline shared with 1000+ nodes. That pipeline adds 12 processing steps per frame and competes for scheduler time with heartbeat traffic.

The dist relay reduces the hot path to 3 steps:

```
Node A writes raw bytes to QUIC stream
  → Dist relay forwards bytes (route lookup + write)
  → Node B reads raw bytes from QUIC stream
```

QUIC provides per-stream ordering, per-stream flow control, and TLS 1.3 encryption at the transport layer. No additional framing or application-level crypto needed.

## Quick Start

```bash
rebar3 get-deps && rebar3 compile
MACULA_DIST_PORT=4434 rebar3 shell
```

## Status

**Prototype** — skeleton project with supervision tree, route table, and stream forwarder. Not yet wired to the SDK's dist driver. See `CLAUDE.md` for architecture details.

## License

Apache-2.0
