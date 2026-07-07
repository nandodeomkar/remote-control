# Phase 1: Protocol Contract & Server Core - Research

**Researched:** 2026-07-07
**Domain:** Versioned wire protocol (WebSocket JSON + binary frames), OS-agnostic Rust async server core, cross-language golden-fixture contract testing (Rust + pure Dart)
**Confidence:** HIGH (all crate/package versions registry-verified 2026-07-07; API shapes cited from docs.rs; one blocking environment gap found — Dart SDK not installed)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

User was offered all four gray areas (CI target, Dart codec home, protocol strictness, fixture format) and answered "no preference" — all four delegated to Claude's discretion. Defaults locked below so downstream agents don't re-litigate.

**CI target**
- **D-01:** Repo is local-only (no git remote). Phase 1's "proven in CI" criterion is satisfied by local test suites: `cargo test` (workspace) and `dart test` (codec package) both green.
- **D-02:** Write a GitHub Actions workflow file (`.github/workflows/ci.yml` — Rust + Dart jobs) as part of Phase 1 anyway; it is cheap, documents the test entrypoints, and activates automatically whenever the repo is pushed to GitHub. Do not block any success criterion on remote CI running.

**Dart codec home**
- **D-03:** Phase 1 creates a **pure Dart package** (no Flutter dependency) for the protocol codec, e.g. `app/packages/remote_protocol/`. The Flutter app scaffold itself is deferred to Phase 2 (the cursor spike needs it; Phase 1 doesn't).
- **D-04:** The package owns: binary mouse-frame encoder/decoder, JSON message codecs for every family, protoVersion constants, and fixture-driven tests. Phase 2's Flutter app imports it via path dependency.

**Protocol strictness**
- **D-05:** Unknown JSON fields are **ignored** on decode (forward-compatible — new minor versions can add fields without breaking old peers). Missing required fields are hard decode errors.
- **D-06:** `protoVersion` is `major.minor` (string "1.0" in `hello`). Major mismatch → server rejects, rejection message carries both versions (per spec §5). Minor mismatch → accepted; peers simply don't use features they don't know.
- **D-07:** Unknown message type `t` after auth → server replies `err` (human-readable, per spec §5) and keeps the connection; it never kills the session over an unknown type.

**Fixture format**
- **D-08:** `protocol/fixtures/` organized per family: `handshake/`, `text/`, `mouse-binary/`, etc. Each scenario is one JSON file: `{ "name", "description", "wire" (JSON object for text frames | hex string for binary frames), "expect" (canonical decoded form) }`. Naming: `NN-scenario-slug.json`.
- **D-09:** Required scenario coverage comes from the roadmap success criteria: auth handshake (challenge/auth/authOk/authFail), IME-revision diff-ops, emoji (multi-byte UTF-8), rapid-backspace, binary mouse move/scroll frames including negative deltas. Both codecs load the same files — no per-language fixture copies.

### Claude's Discretion
- All of the above are Claude-discretion defaults (user explicitly had no preference). Planner may refine details (exact directory names, test harness choices) as long as the observable contract holds: shared fixtures, both codecs green, zero Windows deps in `server-core`, local tests as the gate.

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CONN-07 | Server releases all held keys/buttons when a session ends (no phantom input after mid-drag disconnect) | Executor trait design + dispatcher-owned held-input state map (Pattern 4); session-cleanup runs unconditionally after the read loop exits; mock-executor integration test pattern (Code Example 4); project pitfall 12 mapped to this phase's "session-cleanup hook" half |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

CLAUDE.md exists (GSD-managed). Actionable directives the planner must honor:

- **Locked stack:** Flutter client, Rust server (tokio + tungstenite), WebSocket-only transport (JSON + 9-byte binary mouse frames), UDP broadcast discovery. Do not substitute.
- **Locked security posture:** 6-digit PIN pairing (60s expiry, 5 attempts, lockout), SHA-256-hashed tokens, LAN-only binding.
- **What NOT to use (from embedded STACK.md):** `sha2` 0.10.x pins (start on 0.11); pre-0.9 `rand` API patterns (`thread_rng()`/`gen()` are gone).
- **GSD workflow enforcement:** file changes go through GSD commands (`/gsd-execute-phase` for this work) — plans are executed via the GSD pipeline, not ad-hoc edits.
- **Canonical refs:** design spec §3–§6, §9 is authoritative; `.planning/research/{STACK,PITFALLS,ARCHITECTURE,SUMMARY}.md` must inform planning.

## Summary

Phase 1 is a pure-foundation phase: lock the wire contract in `protocol/` (spec + golden fixtures), build `server-core` (codec → dispatch gates → auth/session FSM → executor traits with mocks), and build a pure Dart codec package that passes the identical fixtures. Everything is CI-testable with zero OS dependencies. The upstream project research (STACK.md, PITFALLS.md, ARCHITECTURE.md — all dated 2026-07-07) already settled the stack and architecture; this phase research verified the Phase-1-specific additions (`hmac` 0.13, `futures-util` 0.3.32, Dart `test`/`crypto`/`characters`) against the registries, confirmed API-breaking changes that would trip up training-data code (tungstenite 0.29 `Message::Binary(Bytes)`, rand 0.10 renames), and audited the local environment.

**Two findings the planner must not miss:**

1. **The spec's auth description as literally written is cryptographically unimplementable.** Spec §4 says the phone replies with `HMAC-SHA256(token, nonce)` and the server "verifies against its stored hash" — but a server holding only `SHA-256(token)` cannot compute or verify an HMAC keyed by the raw token. The only construction satisfying both locked constraints ("tokens stored only as SHA-256 hashes" AND "raw token never crosses the wire after pairing") is: **HMAC key = SHA-256(raw token)**. The phone stores the raw token, derives the key locally; the server verifies with its stored hash directly. This must be locked in `protocol/SPEC.md` and the handshake fixtures before either codec is written (details in Pattern 2 and Pitfall 1).

2. **The Dart SDK is not installed on this machine** (no `dart`, no `flutter`, no `winget`, no `choco`). The Dart codec success criterion cannot execute until it is. The plan needs an explicit environment-setup task (recommended: install the Flutter SDK zip now — it bundles `dart` and unblocks Phase 2 too; fallback: standalone Dart SDK zip). See Environment Availability.

**Primary recommendation:** Build in strict dependency order — `protocol/` spec + fixtures first, then the Rust codec against fixtures, then dispatch/auth/session against mock executors, then the Dart package against the same fixtures, then the dormant CI workflow. Lock the HMAC-key construction and the diff-ops `text` schema (grapheme-counted `{bs, ins}`) in the fixtures on day one; they are the two wire decisions that are expensive to change later.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Wire format definition (schemas, binary layout, versioning) | `protocol/` (contract dir) | — | Single source of truth; both codecs implement it independently (spec §3) |
| Golden fixtures | `protocol/fixtures/` | consumed by both test suites | Cross-language drift prevention; no per-language copies (D-09) |
| Frame encode/decode (Rust) | `server-core::codec` | — | Pure functions, fixture-tested in isolation, no session state |
| Frame encode/decode (Dart) | `app/packages/remote_protocol` | — | Pure Dart, no Flutter dep (D-03); Phase 2 imports via path dependency |
| WS listen/accept, session registry | `server-core::transport` | — | tokio + tokio-tungstenite; per-connection read/write tasks |
| Auth gate, pause gate, routing | `server-core::dispatch` | — | Gates ordered: parse → auth → pause → route (ARCHITECTURE Pattern 2) |
| PIN flow, token hash, lockout, challenge-response | `server-core::auth` | — | Lockout table lives here, NOT in session (must survive reconnect) |
| Held-input tracking + release-on-close (CONN-07) | `server-core::dispatch` (session state) | executor traits (release calls) | Tracking at protocol level makes cleanup executor-impl-agnostic; any future OS crate gets it free |
| OS input injection | **NOT in this phase** | `server-windows` (Phase 2+) | Phase 1 uses mock executors only; zero Windows deps in core |
| Auth proof computation (client side) | `remote_protocol` Dart package | Flutter app (Phase 2+) | HMAC helper belongs in the codec package so the fixture can prove it byte-identical to Rust |
| CI definitions | `.github/workflows/ci.yml` (dormant) | — | D-02: written now, activates on push; local `cargo test` + `dart test` are the real gate |

## Standard Stack

### Core — Rust (`server/server-core`)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| tokio | 1.52.3 | Async runtime | Locked by project STACK.md; features: `rt-multi-thread`, `net`, `sync`, `time`, `macros` [VERIFIED: crates.io 2026-07-07] |
| tokio-tungstenite | 0.29.0 | WebSocket server + test client | Standard tokio WS binding; re-exports tungstenite 0.29; `accept_async` for server, `connect_async` for the fake test client [VERIFIED: crates.io + docs.rs] |
| futures-util | 0.3.32 | `StreamExt`/`SinkExt` for WS streams | Required to `.next()`/`.send()` on `WebSocketStream` [VERIFIED: crates.io] |
| serde + serde_json | 1.0.228 / 1.0.150 | JSON codecs | Locked by STACK.md; derive on protocol structs [VERIFIED: crates.io] |
| sha2 | 0.11.0 | SHA-256 token hashing | Current RustCrypto major (digest 0.11); STACK.md explicitly forbids 0.10 pins [VERIFIED: crates.io] |
| hmac | 0.13.0 | Challenge-response HMAC-SHA256 | The digest-0.11-aligned hmac major: hmac 0.13 requires `digest ^0.11.2`, matching sha2 0.11 (`digest ^0.11`) — confirmed via crates.io dependency graph [VERIFIED: crates.io dependency API] |
| rand | 0.10.2 | 32-byte token, 32-byte nonce, 6-digit PIN | `rand::rng()` (ThreadRng) is a CSPRNG; note post-0.9 renames [VERIFIED: crates.io] |
| thiserror | 2.0.18 | Typed errors in core | STACK.md convention: thiserror in core, anyhow only in binaries [VERIFIED: crates.io] |
| hex | 0.4.3 | Hex encode/decode (wire nonce/mac fields, binary fixtures) | De facto standard; stable since 2021 [VERIFIED: crates.io] |

### Supporting — Rust

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| subtle | 2.6.1 | Constant-time comparison | For PIN string comparison. NOT needed for HMAC verification — `Mac::verify_slice` is already constant-time via `CtOutput` [VERIFIED: crates.io; CITED: docs.rs/hmac/0.13.0] |
| tracing | 0.1.x | Structured logging in core | Optional in Phase 1; if added, enforce the redaction rule (never log `pin`, `auth`, `text`, `clip.*` payloads) from the first line |

### Core — Dart (`app/packages/remote_protocol`)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Dart SDK | ≥3.5 (via Flutter 3.44 bundle or standalone) | Pure Dart package runtime | **Not currently installed — see Environment Availability** |
| test | 1.31.2 | Test runner (`dart test`) | dart.dev first-party test framework [VERIFIED: pub.dev 2026-07-07] |
| crypto | 3.0.7 | `Hmac(sha256, key)` + `sha256` for the auth-proof helper | dart-lang first-party; the standard Dart HMAC/SHA implementation [VERIFIED: pub.dev] |
| characters | 1.4.1 | Grapheme-cluster counting for diff-ops helpers | dart-lang first-party; `String.length` is UTF-16 code units and MUST NOT be used for backspace counts [VERIFIED: pub.dev] |
| lints | 6.1.0 | Analyzer baseline (`package:lints/recommended.yaml`) | dart-lang first-party default for pure packages [VERIFIED: pub.dev] |

`dart:typed_data` (`ByteData`, `Endian.little`) and `dart:convert` (`jsonDecode`/`jsonEncode`) are SDK built-ins — no packages needed for the binary or JSON codecs.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| hand-written Dart codecs | freezed + json_serializable | Project STACK.md already ruled: hand-written keeps fixture mapping explicit for ~15 message types; codegen only if count doubles |
| `hex` crate | base64 for nonce/mac wire fields | base64 saves ~25% bytes (irrelevant on LAN); hex is trivially identical in Dart (`HEX` not even needed — hand-roll 4 lines or use `hex` semantics via `crypto`'s `Digest.toString()` pattern). **Lock hex, lowercase** — simplest cross-language, fixture-friendly |
| two-step envelope parse (`t` + raw `p`) | serde adjacently-tagged enum (`#[serde(tag="t", content="p")]`) | The envelope also carries top-level `seq`; adjacently-tagged enums can't express extra sibling fields cleanly. Two-step parse also gives D-07 (unknown `t` → `err`, keep connection) for free |
| `server-windows` stub crate now | defer crate creation to Phase 2 | **Defer.** An empty stub adds nothing; workspace `members = ["server-core"]` keeps `cargo test --workspace` green with zero Windows deps trivially true |

**Installation:**

```toml
# server/Cargo.toml (workspace root)
[workspace]
resolver = "3"
members = ["server-core"]

[workspace.package]
edition = "2024"
rust-version = "1.85"
```

```toml
# server/server-core/Cargo.toml
[dependencies]
tokio = { version = "1.52", features = ["rt-multi-thread", "net", "sync", "time", "macros"] }
tokio-tungstenite = "0.29"
futures-util = "0.3"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.11"
hmac = "0.13"
rand = "0.10"
subtle = "2.6"
thiserror = "2"
hex = "0.4"
```

```yaml
# app/packages/remote_protocol/pubspec.yaml
name: remote_protocol
description: Wire-protocol codecs for Remote Control (pure Dart, no Flutter).
version: 0.1.0
environment:
  sdk: ^3.5.0
dependencies:
  crypto: ^3.0.7
  characters: ^1.4.1
dev_dependencies:
  test: ^1.31.2
  lints: ^6.0.0
```

**Version verification:** all Rust crates verified via crates.io API on 2026-07-07 (versions + publish dates above); all Dart packages verified via pub.dev API on 2026-07-07. Rust 1.89.0 is installed locally — satisfies edition 2024 (needs ≥1.85).

## Package Legitimacy Audit

Seam command run: `gsd-tools query package-legitimacy check --ecosystem crates …` — all Rust crates returned `OK`. The seam does not support the pub ecosystem; Dart packages were verified directly against the pub.dev registry API and are all dart-lang first-party publishers.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| hmac | crates | 10 yrs (2016) | 8.0M/wk | github.com/RustCrypto/MACs | OK | Approved |
| sha2 | crates | 10 yrs (2016) | 14.6M/wk | github.com/RustCrypto/hashes | OK | Approved |
| rand | crates | 11 yrs (2015) | 25.2M/wk | github.com/rust-random/rand | OK | Approved |
| tokio | crates | 10 yrs (2016) | 14.2M/wk | github.com/tokio-rs/tokio | OK | Approved |
| tokio-tungstenite | crates | 8+ yrs | high | github.com/snapview/tokio-tungstenite | OK | Approved |
| serde / serde_json | crates | 10+ yrs | very high | github.com/serde-rs | OK | Approved |
| futures-util | crates | 8+ yrs | very high | github.com/rust-lang/futures-rs | OK | Approved |
| subtle | crates | 8+ yrs | high | github.com/dalek-cryptography/subtle | OK | Approved |
| thiserror | crates | 6+ yrs | very high | github.com/dtolnay/thiserror | OK | Approved |
| hex | crates | 9+ yrs | very high | github.com/KokaKiwi/rust-hex | OK | Approved |
| test | pub.dev | first-party | — | dart-lang/test | OK (registry + publisher dart.dev) | Approved |
| crypto | pub.dev | first-party | — | dart-lang/crypto | OK (registry + publisher dart.dev) | Approved |
| characters | pub.dev | first-party | — | dart-lang/characters | OK (registry + publisher dart.dev) | Approved |
| lints | pub.dev | first-party | — | dart-lang/lints | OK (registry + publisher dart.dev) | Approved |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram (Phase 1 scope)

```
                       protocol/  (contract — no runtime code)
              SPEC.md · schema/ · fixtures/{handshake,text,mouse-binary}/
                    ▲ loaded at test time by BOTH suites ▲
        ┌───────────┘                                    └────────────┐
        │                                                             │
┌───────┴──────────── server-core (Rust) ───────────────┐  ┌─────────┴─────────────┐
│                                                        │  │ remote_protocol (Dart)│
│ fake WS client (test) ──ws://127.0.0.1:{ephemeral}──┐  │  │  binary codec (9B LE) │
│                                                     ▼  │  │  JSON codecs per fam. │
│ transport: TcpListener → set_nodelay → accept_async    │  │  authProof(token,     │
│   │ per-connection: read task + write task (mpsc)      │  │    nonce) helper      │
│   ▼ raw Message (Binary(Bytes) | Text(Utf8Bytes))      │  │  protoVersion consts  │
│ codec: parse → Msg enum        (fixture-tested)        │  └───────────────────────┘
│   ▼                                                    │   (no Flutter dep;
│ dispatch:                                              │    Phase 2 app imports
│   gate 1: auth state (drop pre-authOk non-handshake)   │    via path dependency)
│   gate 2: pause flag (drop input while paused)         │
│   route by family ──► executor TRAITS only             │
│   held-input state map (keys/buttons down)             │
│   session end (any reason) ──► release all held        │  CONN-07
│   ▼                                                    │
│ auth: PIN verify (60s/5 attempts/lockout table)        │
│       token issue → SHA-256 hash stored                │
│       challenge nonce → HMAC verify (key = stored hash)│
│   ▼                                                    │
│ executors.rs: MouseKeys · Media · Power · Apps ·       │
│               Clipboard traits + MockExecutors (tests) │
└─────────────────────────────────────────────────────────┘
```

Primary flow to trace: fake client connects → `hello` (version check) → `challenge{nonce}` → `auth{mac}` → `authOk` → input messages route to mocks → socket killed mid-drag → cleanup path releases held button on mock.

### Recommended Project Structure

```
protocol/
├── SPEC.md                      # versioned prose spec (protoVersion 1.0)
├── schema/                      # JSON Schema per message family (documentation-grade)
└── fixtures/
    ├── handshake/               # 01-hello-ok.json, 02-challenge.json, 03-auth-ok.json,
    │                            # 04-auth-fail.json, 05-auth-proof.json (token+nonce→mac)
    ├── text/                    # 01-simple-insert.json, 02-ime-revision.json,
    │                            # 03-emoji.json, 04-rapid-backspace.json
    └── mouse-binary/            # 01-move-positive.json, 02-move-negative.json,
                                 # 03-scroll.json, 04-bad-opcode.json, 05-short-frame.json
server/
├── Cargo.toml                   # workspace: members = ["server-core"], resolver 3, edition 2024
└── server-core/
    ├── Cargo.toml
    ├── src/
    │   ├── lib.rs
    │   ├── codec/               # binary.rs (9B frames), json.rs (envelope + payloads)
    │   ├── transport/           # listener.rs, session.rs (registry: id → mpsc Sender + AuthState)
    │   ├── dispatch/            # gates + routing + held-input state + cleanup
    │   ├── auth/                # pin.rs (expiry/attempts/lockout), token.rs (hash/issue), challenge.rs
    │   └── executors.rs         # 5 traits + MockExecutors (cfg(test) or a `mocks` feature)
    └── tests/
        ├── fixtures.rs          # golden-fixture decode tests (both frame kinds)
        └── integration.rs       # real server + fake WS client: pair→auth→input→cleanup
app/
└── packages/
    └── remote_protocol/
        ├── pubspec.yaml
        ├── lib/
        │   ├── remote_protocol.dart        # exports
        │   └── src/binary_codec.dart, json_codec.dart, auth_proof.dart, version.dart
        └── test/
            ├── fixture_test.dart           # loads ../../../protocol/fixtures/**
            └── auth_proof_test.dart
.github/workflows/ci.yml         # dormant (D-02): rust job + dart job
```

### Pattern 1: Fixture files shared by relative path from both suites

**What:** One fixture directory, two loaders. No copies (D-09).
**How:**
- Rust (paths resolve from the crate manifest, immune to test cwd): `concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/fixtures")` — `server/server-core` → up 2 = repo root. [VERIFIED: standard cargo mechanism]
- Dart (`dart test` runs with cwd = package root `app/packages/remote_protocol`): `../../../protocol/fixtures`. Guard with a `Directory.existsSync` check that fails the suite with a clear message if cwd assumptions break. [ASSUMED: `dart test` cwd behavior — verify in first test; it is the documented default]
**Fixture value discipline:** pick binary-frame float values exactly representable in f32 (12.5, -3.25, 100.0, -0.5) so `expect.dx/dy` compare exactly in both languages with no epsilon logic.

### Pattern 2: Challenge-response auth — the exact construction (LOCK THIS FIRST)

**What:** Reconciles spec §4's contradiction (server can't verify `HMAC(raw_token, nonce)` from a stored SHA-256 hash).

```
Pairing (once, over LAN — documented tradeoff):
  phone → pin{pin:"042137"}          # 6 digits, zero-padded, string
  server verifies (60s expiry, 5 attempts, per-source lockout)
  server → pairOk{token: hex(32 random bytes)}     # the ONLY time token crosses the wire
  phone stores raw token (secure storage, Phase 2+); server stores SHA-256(token) only

Reconnect (every session):
  server → challenge{nonce: hex(32 random bytes)}  # fresh per connection
  phone  → auth{mac: hex( HMAC-SHA256( key = SHA-256(raw token), msg = nonce bytes ) )}
  server → recompute HMAC with its STORED HASH as key; Mac::verify_slice (constant-time)
  server → authOk | authFail{reason}
```

**Why this construction:** the server's stored value IS the HMAC key, so it can verify; the raw token never appears on the wire post-pairing; a sniffed `mac` is useless (nonce is fresh per connection → replay dead); a rogue beacon-spoofing server learns only `HMAC(hash, its_own_nonce)`, which it cannot replay to the real server. Known residual risk (out of v1 scope, LAN threat model): a live MITM relay could forward challenges; defeating that needs TLS/channel binding — explicitly deferred, matches spec's LAN-only posture.
**Fixture:** `05-auth-proof.json` carries a fixed token + fixed nonce + expected mac hex — this is the fixture that proves the Rust and Dart HMAC constructions are byte-identical. Confidence: HIGH (construction follows from locked constraints; hmac 0.13 API cited from docs.rs).

### Pattern 3: Two-step envelope parse (D-05/D-06/D-07 compliance)

**What:** Parse `{t, seq?, p?}` into an envelope first; then match `t` and parse `p` into the typed payload.

```rust
// Source: serde standard patterns; shape dictated by spec §5 example {"t","seq","p"}
#[derive(serde::Deserialize)]
struct Envelope {
    t: String,
    #[serde(default)] seq: Option<u64>,
    #[serde(default)] p: serde_json::Value,
}
// match envelope.t.as_str():
//   known family  -> serde_json::from_value::<Payload>(envelope.p)?   // missing field = hard error
//   unknown, pre-auth  -> drop silently (auth gate)
//   unknown, post-auth -> reply err{...}, keep connection (D-07)
```

**Critical:** do NOT add `#[serde(deny_unknown_fields)]` anywhere — it violates D-05. Serde's default (ignore unknown fields) is exactly the locked behavior; Dart's `jsonDecode` + explicit key reads gives the same semantics for free (read required keys, throw `FormatException` if absent, ignore the rest).

### Pattern 4: Dispatcher-owned held-input state + unconditional cleanup (CONN-07)

**What:** The dispatcher (not the executor impl) tracks what is currently held, per session, and releases everything when the session ends for ANY reason.

```rust
// server-core/src/dispatch/held.rs — protocol-level types only, zero OS types
#[derive(Default)]
pub struct HeldInput {
    buttons: std::collections::HashSet<Button>,  // protocol Button enum
    keys: std::collections::HashSet<KeyCode>,    // protocol key code
}
impl HeldInput {
    pub fn release_all(&mut self, mk: &dyn MouseKeys) {
        for b in self.buttons.drain() { mk.button_up(b); }
        for k in self.keys.drain()    { mk.key_up(k); }
    }
}
```

**Placement rule:** the per-connection task runs `held.release_all(&*exec.mouse_keys)` AFTER the read loop exits — on clean close, error, auth revoke, and pause-with-drag-active alike (pause releases first, per project pitfall 12). Structure it so cleanup is unskippable (run it in the code path after the loop, not inside a match arm).
**Trait shape consequence:** `MouseKeys` needs explicit `button_down/button_up` and `key_down/key_up` (not just `tap`) — the state map updates on `down`, clears on `up`.
**Traits are sync** (`&self` methods, `Send + Sync`, injected as `Arc<dyn MouseKeys + Send + Sync>` etc.): enigo's SendInput is synchronous and cheap; sync traits keep mocks trivial and dispatch inline in the read task (ARCHITECTURE hot-path rule). Media/Power/Apps/Clipboard traits are defined in this phase but only exercised via mocks.

### Pattern 5: Integration-test harness (real server, fake client, ephemeral port)

**What:** The canonical tokio-tungstenite test shape — no mocked sockets, real TCP on 127.0.0.1:0.

```rust
// Source: tokio-tungstenite server example (github.com/snapview/tokio-tungstenite) + docs.rs 0.29
async fn spawn_test_server(exec: MockExecutors) -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = tokio::spawn(server_core::run(listener, exec));  // accept loop
    (addr, handle)
}

#[tokio::test]
async fn pair_auth_input_flow() {
    let (addr, _srv) = spawn_test_server(mocks.clone()).await;
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}")).await.unwrap();
    // drive hello → pin → pairOk → reconnect → challenge → auth → authOk → input …
    // wrap EVERY recv in tokio::time::timeout(Duration::from_secs(2), ws.next())
}
```

**Timing tests split:** PIN expiry (60s) and lockout (5 min) are tested at the auth-manager unit level with `#[tokio::test(start_paused = true)]` + `tokio::time::advance` — paused time works there because no real I/O is involved. Socket integration tests stay on wall-clock with short timeouts; mixing paused time with real TCP readiness causes hangs/flakes. [ASSUMED: tokio paused-time/IO interaction — well-documented tokio behavior, verify if a paused-time socket test is ever attempted]
**Also assert in integration tests:** `stream.set_nodelay(true)` was applied (call `nodelay()` on the accepted stream before handshake or expose it) — bakes the Phase-2 latency prerequisite in now (project pitfall 3).

### Anti-Patterns to Avoid

- **OS types in core:** no `#[cfg(windows)]`, no HWND-shaped IDs in traits — kills the mock-CI story and the Phase-2+ portability seam (ARCHITECTURE Anti-Pattern 3).
- **`deny_unknown_fields` / strict Dart key validation:** violates D-05 forward compatibility.
- **Testing codecs through the socket:** codec fixture tests must be pure function tests; only the flow tests use the harness. Mixing them makes fixture failures hard to localize.
- **Storing lockout state on the session:** lockout must survive disconnect/reconnect — it lives in the auth manager keyed by source IP (ARCHITECTURE integration seam table).
- **Executor-impl-owned cleanup:** putting held-state in the (future) enigo executor means every future OS impl re-solves CONN-07; dispatcher-level tracking solves it once.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HMAC-SHA256 / SHA-256 | any manual construction | `hmac` 0.13 + `sha2` 0.11 (Rust), `package:crypto` (Dart) | Locked project security constraint; RustCrypto/dart-lang are the audited standards |
| Constant-time MAC compare | `==` on byte arrays | `Mac::verify_slice` (built-in CT), `subtle` for PIN | Timing-oracle free by construction; hand-rolled CT compare is a classic mistake |
| Secure randomness | timestamp/xorshift seeds | `rand::rng()` (CSPRNG ThreadRng) | Token/nonce/PIN are security-bearing values |
| WebSocket framing | raw TCP frame parser | tokio-tungstenite / (Dart side: N/A this phase) | Handshake, masking, fragmentation, control frames — all handled |
| JSON parse | manual tokenizer | serde_json / `dart:convert` | Obvious, but also: serde's ignore-unknown default IS the D-05 policy |
| Grapheme counting (Dart) | `String.length` math | `package:characters` | UTF-16 code-unit counts corrupt emoji backspace semantics |
| f32 little-endian bytes | manual bit twiddling | `f32::to_le_bytes/from_le_bytes` (Rust), `ByteData` + `Endian.little` (Dart) | Built-ins on both sides; endianness bugs are silent |

**Key insight:** every cryptographic and encoding primitive this phase needs is a first-party or de-facto-standard library on both sides. The only genuinely custom code is the protocol logic itself (gates, FSM, held-state) — which is exactly what the fixtures and mock-executor tests exist to prove.

## Common Pitfalls

### Pitfall 1: Implementing spec §4's auth text literally
**What goes wrong:** Codec/auth written as "verify HMAC(raw_token, nonce) against SHA-256(token)" — mathematically impossible; discovered only when the verify path is wired, forcing a fixture rewrite.
**How to avoid:** Lock Pattern 2 (key = SHA-256(token)) in `protocol/SPEC.md` and the `05-auth-proof.json` fixture in the FIRST plan task, before either codec exists.
**Warning signs:** any code path that needs the raw token on the server after pairing.

### Pitfall 2: tungstenite 0.29 payload types broke old snippets
**What goes wrong:** Training-data code matches `Message::Binary(Vec<u8>)` / `Message::Text(String)` — doesn't compile. 0.29 uses `Message::Binary(Bytes)` and `Message::Text(Utf8Bytes)` [CITED: docs.rs/tungstenite/0.29.0].
**How to avoid:** Match on `Binary(b)` and use `b.as_ref() as &[u8]`; construct with `Message::binary(vec)` / `Message::text(string)` (both take `Into<…>` — `Vec<u8>`/`String` still convert via `From`).

### Pitfall 3: rand 0.10 API renames
**What goes wrong:** `rand::thread_rng()`, `.gen()`, `.gen_range()` — all pre-0.9 names, won't compile.
**How to avoid:** `rand::rng()`, `.random()`, `.random_range(0..=999_999)` (PIN — format with `{:06}` for zero padding), `.fill_bytes(&mut [0u8; 32])` via `RngCore` for token/nonce. [VERIFIED: STACK.md registry check + rand 0.9 migration notes]

### Pitfall 4: Backspace counts in the wrong unit
**What goes wrong:** `text` diff-ops count deletions in UTF-16 units (Dart `String.length`) or bytes; an emoji backspace becomes 2+ Backspace taps on the PC → corrupts adjacent text.
**How to avoid:** SPEC.md defines `bs` as **extended grapheme clusters** (UAX #29). Dart computes with `characters`; Rust side merely replays `bs` Backspace taps (no segmentation needed server-side in Phase 1). The emoji and rapid-backspace fixtures lock this: e.g. old `"hi👍"` → new `"hi"` must produce `bs: 1`, not 2.
**Recommended `text` payload (prescriptive):** `{ "t":"text", "seq":N, "p": { "bs": <int ≥0>, "ins": "<string>" } }` — delete `bs` graphemes at the end, then insert. Computed client-side as: `bs = graphemes(old) − graphemes(commonPrefix(old,new))`, `ins = new[len(commonPrefix):]`. Handles IME revision ("thw"→"the " ⇒ bs 1, ins "e "), rapid backspace (bs N, ins ""), and any mid-string edit (worst case retypes the tail). Simpler than an ops array and covers every phone-IME case; the spec's "insert/delete at position" is satisfied with position implicitly = end-of-committed-text.

### Pitfall 5: Fixture float/hex mismatches across languages
**What goes wrong:** Binary fixtures stored as JSON float arrays hit f64→f32 rounding differences; or mixed-case hex fails strict decoders.
**How to avoid:** D-08 already says binary `wire` is a hex string — keep it lowercase, exactly 18 hex chars for 9 bytes; `expect.dx/dy` values chosen f32-exact (Pattern 1).

### Pitfall 6: Decode leniency where the spec demands strictness (and vice versa)
**What goes wrong:** Binary decoder accepts 8- or 10-byte frames, or unknown opcodes, silently; or JSON decoder hard-errors on unknown fields.
**How to avoid:** Binary frames: exact length 9, opcode ∈ {0x01, 0x02}, reject non-finite f32 (NaN/±Inf → drop frame, count it) — include `04-bad-opcode.json` / `05-short-frame.json` negative fixtures with `"expect": {"error": true}`. JSON: unknown fields ignored (D-05), missing required fields error, unknown `t` handled per D-07.

### Pitfall 7: Pre-auth resource exhaustion
**What goes wrong:** Unauthenticated LAN peer sends a 100MB text frame; tungstenite's defaults are generous.
**How to avoid:** Pass `WebSocketConfig` with tightened `max_message_size`/`max_frame_size` (e.g. 64KB — largest legit message is a clipboard payload, which isn't even in Phase 1) via `accept_async_with_config`. Assert the pre-auth gate drops everything except the handshake family (spec §5) in a dedicated test.

### Pitfall 8: `dart test` invoked from repo root
**What goes wrong:** Fixture relative path `../../../protocol/fixtures` resolves only when cwd = package root; running `dart test app/packages/remote_protocol` from the root breaks it.
**How to avoid:** Document the canonical invocation (`cd app/packages/remote_protocol && dart test`) in the CI workflow and README; add the existence guard from Pattern 1.

## Code Examples

### 1. Binary mouse-frame codec — Rust

```rust
// server-core/src/codec/binary.rs — spec §5: [opcode u8][dx f32 LE][dy f32 LE]
pub const OP_MOVE: u8 = 0x01;
pub const OP_SCROLL: u8 = 0x02;

pub enum MouseFrame { Move { dx: f32, dy: f32 }, Scroll { dx: f32, dy: f32 } }

pub fn decode(buf: &[u8]) -> Result<MouseFrame, CodecError> {
    if buf.len() != 9 { return Err(CodecError::BadLength(buf.len())); }
    let dx = f32::from_le_bytes(buf[1..5].try_into().unwrap());
    let dy = f32::from_le_bytes(buf[5..9].try_into().unwrap());
    if !dx.is_finite() || !dy.is_finite() { return Err(CodecError::NonFinite); }
    match buf[0] {
        OP_MOVE => Ok(MouseFrame::Move { dx, dy }),
        OP_SCROLL => Ok(MouseFrame::Scroll { dx, dy }),
        op => Err(CodecError::UnknownOpcode(op)),
    }
}
```

### 2. Binary mouse-frame codec — Dart

```dart
// lib/src/binary_codec.dart — dart:typed_data built-ins only
import 'dart:typed_data';

Uint8List encodeMove(double dx, double dy) {
  final b = ByteData(9)
    ..setUint8(0, 0x01)
    ..setFloat32(1, dx, Endian.little)
    ..setFloat32(5, dy, Endian.little);
  return b.buffer.asUint8List();
}

MouseFrame decode(Uint8List bytes) {
  if (bytes.length != 9) throw const FormatException('frame must be 9 bytes');
  final b = ByteData.sublistView(bytes);
  final dx = b.getFloat32(1, Endian.little);
  final dy = b.getFloat32(5, Endian.little);
  // opcode switch + finite check mirrors Rust
  ...
}
```

### 3. Auth proof — both sides (must match `05-auth-proof.json`)

```rust
// Source: docs.rs/hmac/0.13.0 usage pattern (CITED)
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
type HmacSha256 = Hmac<Sha256>;

// server side: verify with STORED hash as key
pub fn verify_auth(stored_hash: &[u8; 32], nonce: &[u8], mac_hex: &str) -> bool {
    let mut mac = HmacSha256::new_from_slice(stored_hash).expect("any key size ok");
    mac.update(nonce);
    let Ok(received) = hex::decode(mac_hex) else { return false };
    mac.verify_slice(&received).is_ok()   // constant-time
}

// client-equivalent (used in tests / fixture generation):
pub fn auth_proof(raw_token: &[u8], nonce: &[u8]) -> String {
    let key = Sha256::digest(raw_token);            // key = SHA-256(token)
    let mut mac = HmacSha256::new_from_slice(&key).unwrap();
    mac.update(nonce);
    hex::encode(mac.finalize().into_bytes())
}
```

```dart
// lib/src/auth_proof.dart — package:crypto (dart-lang first-party)
import 'package:crypto/crypto.dart';

String authProof(List<int> rawToken, List<int> nonce) {
  final key = sha256.convert(rawToken).bytes;       // key = SHA-256(token)
  final mac = Hmac(sha256, key).convert(nonce);
  return mac.toString();                            // lowercase hex
}
```

### 4. CONN-07 integration test (the phase's headline test)

```rust
#[tokio::test]
async fn disconnect_mid_drag_releases_held_input() {
    let mocks = MockExecutors::recording();
    let (addr, _srv) = spawn_test_server(mocks.clone()).await;
    let mut ws = authed_client(addr).await;               // helper: full handshake
    ws.send(json_msg("drag", r#"{"action":"start","button":"left"}"#)).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await; // let it route
    drop(ws);                                             // kill socket mid-drag
    mocks.wait_for(|calls| calls.contains(&Call::ButtonUp(Button::Left)),
                   std::time::Duration::from_secs(2)).await;
    // also assert: no phantom state — a second session starts with empty HeldInput
}
```

### 5. Dormant CI workflow (D-02)

```yaml
# .github/workflows/ci.yml — activates automatically if repo is ever pushed to GitHub
name: ci
on: [push, pull_request]
jobs:
  rust:
    runs-on: ubuntu-latest          # proves zero-Windows-deps claim by construction
    defaults: { run: { working-directory: server } }
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
        with: { workspaces: server }
      - run: cargo test --workspace
  dart:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: app/packages/remote_protocol } }
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with: { sdk: stable }
      - run: dart pub get
      - run: dart analyze --fatal-infos
      - run: dart test
```

[ASSUMED: action versions (checkout@v4, rust-toolchain@stable, rust-cache@v2, setup-dart@v1) — standard 2025-era pins from training; workflow is dormant per D-01/D-02 so staleness is zero-risk and self-corrects on first real push.]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `Message::Binary(Vec<u8>)`, `Text(String)` | `Binary(Bytes)`, `Text(Utf8Bytes)` | tungstenite ~0.26 (2025) | Old snippets don't compile; use `Message::binary()/text()` constructors |
| `rand::thread_rng()`, `.gen()` | `rand::rng()`, `.random()` | rand 0.9 (2025) → 0.10 | Old snippets don't compile |
| sha2/hmac 0.10/0.12 (digest 0.10) | sha2 0.11 + hmac 0.13 (digest 0.11) | RustCrypto majors, Mar 2026 | Keep all RustCrypto crates on digest 0.11; mixing majors fails type-checking |
| cargo resolver "2", edition 2021 | resolver "3", edition 2024 (Rust ≥1.85) | Rust 1.85 (Feb 2025) | Local rustc 1.89 supports it; use in workspace root |
| `hmac` 0.13 also adds `HmacReset` variants | plain `Hmac` sufficient here | 0.13 (Mar 2026) | No reset needed — one MAC per challenge |

**Deprecated/outdated:** nothing else in this phase's scope; all chosen crates/packages are current majors as of 2026-07-07.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `dart test` runs with cwd = package root, making `../../../protocol/fixtures` resolve | Pattern 1 | LOW — first fixture test fails loudly; guard + fallback path resolution is a 5-line fix |
| A2 | GitHub Actions action versions (checkout@v4, setup-dart@v1, rust-cache@v2) are current | Code Example 5 | NONE now (workflow dormant, D-01); self-evident on first real push |
| A3 | tokio paused time (`start_paused`) must not be mixed with real-socket tests | Pattern 5 | LOW — if wrong, tests just also work; guidance is conservative |
| A4 | Dart SDK constraint `^3.5.0` is satisfied by whatever SDK gets installed (Flutter 3.44 bundles Dart ≥3.5) | Standard Stack | LOW — adjust one pubspec line after install; verify with `dart --version` in the setup task |
| A5 | Standalone Dart SDK official zip URL pattern (`storage.googleapis.com/dart-archive/...`) if the Flutter-bundle route is not taken | Environment Availability | LOW — dart.dev/get-dart documents current links; setup task should follow the docs page |

All other factual claims in this document are [VERIFIED] against crates.io/pub.dev registries + the package-legitimacy seam, or [CITED] from docs.rs official documentation, or restate the locked design spec / upstream project research.

## Open Questions

1. **How is the Dart SDK delivered on this machine?**
   - What we know: no `dart`, `flutter`, `winget`, or `choco` on PATH (verified via both Git Bash and PowerShell). Rust 1.89 is present.
   - What's unclear: whether the user prefers the Flutter SDK (bundles Dart; needed by Phase 2 anyway; ~2GB zip, extract + PATH, no admin) or the standalone Dart SDK (~250MB).
   - Recommendation: plan a `checkpoint:human-verify` environment-setup task early in the phase: install Flutter SDK stable (zip extract, add `flutter\bin` to PATH) — one install serves Phases 1–7. Gate all Dart tasks behind it.

2. **Global vs per-source-IP lockout.**
   - What we know: spec §4 says "5-minute lockout per source IP"; project PITFALLS (Pitfall 9) recommends a global counter because LAN attackers rotate IPs freely.
   - Recommendation: implement per-source-IP per the locked spec (success criterion 3 mirrors it), and add a cheap global cap (e.g. 20 total failures → lockout regardless of IP) as discretionary hardening — it's ~10 lines inside the same auth-manager table and doesn't change the wire contract.

3. **Does `pairOk` carry the raw token in plaintext during pairing?**
   - What we know: some message must deliver the token once; spec §4 step 4 implies it; PITFALLS Pitfall 9 calls plaintext-once-during-pairing "a documented tradeoff for v1" (alternative: PIN-derived encryption).
   - Recommendation: plaintext-once during pairing, explicitly documented as a tradeoff in `protocol/SPEC.md`'s security notes. PIN-derived wrapping is a v2 minor-version candidate; don't spend Phase 1 budget on it.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust toolchain (cargo/rustc) | server-core build + tests | ✓ | 1.89.0 (supports edition 2024) | — |
| Dart SDK | remote_protocol package + `dart test` (success criterion 1) | ✗ | — | Install Flutter SDK zip (bundles dart; also unblocks Phase 2) OR standalone Dart SDK zip |
| git | commits, GSD workflow | ✓ | 2.53.0 | — |
| winget / choco | convenience installers | ✗ | — | Manual zip download from official flutter.dev / dart.dev archives |
| GitHub remote / Actions | none (D-01: local-only) | n/a | — | Local `cargo test` + `dart test` are the gate |

**Missing dependencies with no fallback:** none.

**Missing dependencies with fallback:**
- **Dart SDK (BLOCKING for ~half the phase):** no package manager available, so the install is a manual zip download + PATH entry. Recommended: Flutter SDK stable from docs.flutter.dev (extract to e.g. `C:\dev\flutter`, add `C:\dev\flutter\bin` to user PATH → provides `dart` and `flutter`). The planner MUST sequence Rust-side tasks first and gate Dart-side tasks behind a setup task with a `dart --version` verification step.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework (Rust) | built-in `cargo test` (libtest) — no config file needed |
| Framework (Dart) | `package:test` 1.31.2 — no config file needed (defaults fine) |
| Config file | none — see Wave 0 (package scaffolds ARE the config) |
| Quick run command | `cargo test -p server-core <test_name>` (from `server/`) |
| Full suite command | `cd server && cargo test --workspace` then `cd app/packages/remote_protocol && dart test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CONN-07 | Session end releases all held keys/buttons (mid-drag disconnect → mock sees `button_up`) | integration | `cargo test -p server-core --test integration disconnect_mid_drag` | ❌ Wave 0 |
| SC-1 | Golden fixtures decode identically in Rust codec | unit | `cargo test -p server-core --test fixtures` | ❌ Wave 0 |
| SC-1 | Same fixtures decode identically in Dart codec | unit | `dart test test/fixture_test.dart` (from package root) | ❌ Wave 0 |
| SC-2 | Full pair → challenge-response → input flow; pre-auth and paused traffic dropped | integration | `cargo test -p server-core --test integration` | ❌ Wave 0 |
| SC-3 | PIN 60s expiry / 5 attempts / lockout; token stored as SHA-256 only; HMAC verify | unit (paused tokio time) | `cargo test -p server-core auth::` | ❌ Wave 0 |
| SC-5 | Zero Windows deps | build-level | `cargo test --workspace` on any OS + `cargo tree -p server-core` shows no `windows`/`winapi` (optional CI grep) | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `cargo test -p server-core` (Rust tasks) / `dart test` (Dart tasks) — both run in seconds
- **Per wave merge:** full suite (both commands above)
- **Phase gate:** both suites green + fixture files identical inputs to both = the phase's success criteria 1–5, before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `server/` workspace + `server-core` crate scaffold (Cargo.toml files) — enables all Rust tests
- [ ] `server/server-core/tests/fixtures.rs` — covers SC-1 (Rust side)
- [ ] `server/server-core/tests/integration.rs` — covers SC-2, CONN-07
- [ ] `app/packages/remote_protocol/` scaffold (`dart create -t package` or manual) — enables Dart tests
- [ ] `app/packages/remote_protocol/test/fixture_test.dart` — covers SC-1 (Dart side)
- [ ] `protocol/fixtures/**` — the shared inputs everything above consumes (create FIRST)
- [ ] Framework install: **Dart SDK** (see Environment Availability — blocking for Dart-side gaps)

## Security Domain

`security_enforcement: true`, ASVS level 1. This phase IS the project's security foundation — auth, session, and input-validation controls are its deliverables, not add-ons.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Challenge-response HMAC-SHA256 (Pattern 2); PIN rules 60s/5/lockout; `Mac::verify_slice` constant-time; PIN compare via `subtle` |
| V3 Session Management | yes | Session registry with `PreAuth → PinPending → Authed` FSM; auth gate drops pre-`authOk` traffic; session cleanup releases held input (CONN-07); lockout state outlives sessions |
| V4 Access Control | yes (minimal) | Pause gate (input dropped while paused); power-family `confirm` gating is designed into the protocol now (executed in Phase 5) |
| V5 Input Validation | yes | Strict binary decode (length/opcode/finite floats); JSON required-field errors; `WebSocketConfig` frame/message size caps pre-auth; PIN format validation |
| V6 Cryptography | yes | `sha2`/`hmac` (RustCrypto), `package:crypto` (dart-lang) — never hand-roll; CSPRNG (`rand::rng()`) for token/nonce/PIN |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| LAN credential sniffing | Information disclosure | Token crosses wire once (pairing, documented); post-pairing only HMAC proofs — useless to a sniffer |
| Replay of captured auth | Spoofing | Fresh 32-byte nonce per connection; proof bound to nonce |
| Rogue server / beacon spoofing | Spoofing | Challenge-response yields nothing replayable to the real server (residual: live MITM relay — out of v1 LAN threat model, documented) |
| PIN brute force | Elevation of privilege | 5 attempts, 60s expiry, 5-min per-IP lockout (+ discretionary global cap, Open Q2) |
| Pre-auth memory DoS | Denial of service | tungstenite size limits + auth gate drops non-handshake frames |
| Timing oracle on verify | Information disclosure | `verify_slice` (CT); `subtle::ConstantTimeEq` for PIN |
| Secrets in logs | Information disclosure | Redaction rule from line one: never log `pin`/`auth`/`text` payloads or tokens (PITFALLS security table) |
| Malicious frame values (NaN deltas, huge bs counts) | Tampering | Non-finite floats rejected at codec; cap `bs` at a sane bound (e.g. 10,000) at dispatch |

## Sources

### Primary (HIGH confidence)
- crates.io registry API (2026-07-07) — versions + publish dates for all 11 Rust crates; hmac 0.13 ↔ sha2 0.11 digest-0.11 alignment confirmed via dependency endpoints
- pub.dev registry API (2026-07-07) — test 1.31.2, crypto 3.0.7, characters 1.4.1, lints 6.1.0, collection, convert
- `gsd-tools query package-legitimacy check --ecosystem crates` — all crates `OK` (ages 6–11 yrs, 8M–25M weekly downloads, official repos)
- Local environment probes — rustc/cargo 1.89.0 present; dart/flutter/winget/choco absent (verified both shells)
- Design spec `docs/superpowers/specs/2026-07-07-remote-control-design.md` §3–§6, §9 — authoritative, direct read
- Project research `.planning/research/{STACK,PITFALLS,ARCHITECTURE}.md` (2026-07-07) — upstream verified findings inherited

### Secondary (MEDIUM confidence)
- docs.rs/tungstenite/0.29.0 — `Message` enum payload types (`Bytes`/`Utf8Bytes`), constructors [CITED]
- docs.rs/hmac/0.13.0 — `new_from_slice`/`update`/`finalize`/`verify_slice` API [CITED]
- docs.rs/tokio-tungstenite/0.29.0 — `accept_async`/`connect_async`/`client_async` exports, tungstenite 0.29 re-export [CITED]

### Tertiary (LOW confidence / training knowledge)
- GitHub Actions action version pins (dormant workflow — zero current risk)
- `dart test` cwd behavior; tokio paused-time-vs-real-IO interaction (both guarded with cheap runtime checks)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every version registry-verified today; legitimacy seam clean; digest-major alignment confirmed
- Architecture: HIGH — inherited from ARCHITECTURE.md (validated against comparable systems) + locked spec; Phase-1 additions (auth construction, held-state placement, envelope parse) follow deterministically from locked constraints
- Pitfalls: HIGH for API-breakage items (compiler-enforced); MEDIUM for test-harness nuances (A1, A3)
- Environment: HIGH — probed directly; Dart absence is a fact, not a guess

**Research date:** 2026-07-07
**Valid until:** ~2026-08-07 (stable ecosystem; re-check crate minors if planning slips past a month)
