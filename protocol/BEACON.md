# Discovery Beacon Contract

**Status:** Locked (Phase 3). `protocol/SPEC.md` explicitly excludes discovery —
**this document owns the beacon wire format.** The design spec §4 names the
fields; this doc is the normative byte-level contract, fixture-backed like
every other wire artifact in this project (see `fixtures/README.md`).

## Datagram

One UTF-8 JSON object per UDP datagram. No framing, no trailing newline
required (decoders must accept either).

```json
{ "v": 1, "app": "remote-control", "name": "OMKAR-LAPTOP", "guid": "9f3c-test-guid", "port": 17777, "proto": "1.0" }
```

| Key | Type | Meaning | Constraints |
|-----|------|---------|-------------|
| `v` | int | Beacon **format** version (independent of `proto`) | Currently `1` |
| `app` | string | Application discriminator | Literal `"remote-control"` |
| `name` | string | Human-readable PC name (`COMPUTERNAME`) | Length ≤ 64 |
| `guid` | string | Machine GUID — identifies the PC across IP changes | Length ≤ 64, non-empty |
| `port` | int | The WebSocket port to connect to — **travels IN the beacon**, so ws-port changes need no client update | 1..65535 |
| `proto` | string | Wire-protocol version (SPEC §2) | e.g. `"1.0"` |

The payload contains **exactly** these six keys and nothing else. No PIN,
token, token hash, or any other secret may ever enter the beacon (threat
T-03-01).

## Transport

- **Destination:** UDP port **17778** (server-side env override:
  `RC_BEACON_PORT`, mirroring `RC_PORT`).
- **Cadence:** sent every **2 seconds**.
- **Fan-out:** one send per up, non-loopback IPv4 interface, addressed to
  that interface's **subnet-directed broadcast address** (e.g.
  `192.168.1.255` for `192.168.1.7/24`). A single `255.255.255.255` send
  exits only ONE interface chosen by the routing table — VPN/WSL/Hyper-V
  adapters silently eat it — so per-interface directed broadcast is
  mandatory. Interfaces are re-enumerated on every tick (adapters churn).

## Client validation (all-or-nothing, silent drop)

A receiver MUST apply these checks in order and silently drop the datagram
on the first failure. Parsing must be **total** — no exception may escape
the listener (the beacon is untrusted network input):

1. Datagram length ≤ **512 bytes**.
2. Parses as a single JSON object.
3. `v == 1` (unknown format versions are dropped, not best-effort parsed).
4. `app == "remote-control"`.
5. Typed field checks: `name` string ≤ 64, `guid` non-empty string ≤ 64,
   `port` int in 1..65535, `proto` string.
6. **Unknown fields are ignored** (same forward-compat rule as SPEC §1) —
   a beacon with extra keys still decodes.

## Security posture

The beacon is **unauthenticated broadcast**. It may update a device list and
short-circuit reconnect backoff, but it must **never trigger sending
secrets**: a connection attempt prompted by a beacon still runs the full
challenge-response handshake (SPEC §4), so a spoofed beacon harvests
nothing. Beacon floods are bounded by the 512-byte cap, total parsing, and
GUID-debounced device-list updates on the client.

## Versioning

`v` is bumped only for incompatible beacon-format changes. Additive fields
do NOT bump `v` (rule 6 above makes them safe). `proto` carries the
wire-protocol version for display/compatibility hints; beacon validity does
not depend on it.

## Fixtures

Shared fixtures live in `fixtures/beacon/` using the standard
`name`/`description`/`wire`/`expect` schema (`fixtures/README.md`):

- **Decode-ok fixtures** (`01`, `02`): `expect` is the canonical decoded
  beacon `{name, guid, port, proto}` — `v` and `app` are validation gates,
  not decoded state; unknown fields present in `wire` never appear in
  `expect`.
- **Drop fixtures** (`03`–`06`): `expect` is `{"error": true, ...}` — the
  datagram must be silently dropped. Extra fields like `reason` are
  informational.

The Rust encoder test asserts `encode_beacon` output equals the `wire`
object of `01-valid.json`; the Dart decoder test drives validation against
all six files. Per-language fixture copies are forbidden (D-09).
