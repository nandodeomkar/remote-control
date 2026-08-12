# Walking Skeleton — Remote Control

**Phase:** 1
**Generated:** 2026-07-07

## Capability Proven End-to-End

A fake WebSocket client completes `hello → challenge → PIN pairing → pairOk → challenge-response reconnect auth → one input message` routed through dispatch gates to a recording mock executor — proven by `cargo test -p server-core --test integration walking_skeleton_pair_auth_input` (plus the reconnect and CONN-07 tests).

This is the thinnest end-to-end slice for this domain: no DB, no UI, no deployment — the "full stack" is wire bytes → codec → auth FSM → dispatch gates → executor trait, and the skeleton exercises every layer with real TCP on 127.0.0.1.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Contract source of truth | `protocol/` dir: SPEC.md + JSON schema + golden fixtures; both codecs test against the SAME files | Cross-language drift prevention (D-08/D-09); protocol-first design per spec §3 |
| Server runtime | Rust workspace `server/` (resolver 3, edition 2024): `server-core` only; `server-windows` deferred to Phase 2 | Zero Windows deps keeps core CI-testable on any OS; empty stub adds nothing (RESEARCH) |
| Async/WS stack | tokio 1.52 + tokio-tungstenite 0.29 + futures-util 0.3 | Locked by project STACK.md; registry-verified 2026-07-07 |
| Auth construction | `mac = HMAC-SHA256(key = SHA-256(raw token), msg = nonce)`; server stores only SHA-256(token) and verifies with the stored hash as key | Only construction satisfying both locked constraints (hash-only storage + token never re-crosses wire); fixes spec §4's literal text (RESEARCH Pattern 2) |
| Handshake FSM | `AwaitingHello → AwaitingAuth → Authed`; FSM lives in transport/session, post-auth routing in dispatch | Single challenge path serves both pairing (pin) and reconnect (auth); gates structurally ordered auth → pause → route |
| Held-input ownership | Dispatcher-owned `HeldInput` + unconditional `release_all` after the read loop | CONN-07 solved once at protocol level; every future OS executor gets it free (RESEARCH Pattern 4) |
| Message envelope | Two-step parse: `{t, seq?, p?}` envelope, then typed payload by `t`; unknown fields ignored, missing required fields hard-error, unknown `t` → err reply | D-05/D-06/D-07 locked strictness; adjacently-tagged serde enums can't carry sibling `seq` |
| Client codec home | Pure Dart package `app/packages/remote_protocol` (no Flutter dep) | D-03/D-04; Phase 2 Flutter app imports via path dependency |
| Mocks | Recording mocks compiled unconditionally in `executors::mock` (shared Call log + Notify-based wait_for) | Integration tests in `tests/` need them; OS-free so no cost to the zero-Windows-deps claim |
| Test gate | Local `cargo test --workspace` + `dart test` (D-01); dormant `.github/workflows/ci.yml` (D-02) | Repo is local-only; workflow activates on first push |
| Directory layout | `protocol/` + `server/server-core/src/{codec,auth,dispatch,transport,executors}` + `app/packages/remote_protocol/` | Spec §3 monorepo; module tree fixed in Plan 02 so Wave 3 plans implement in parallel with zero file overlap |

## Stack Touched in Phase 1 (adapted to domain — no DB/UI/deployment)

- [ ] Project scaffold (Rust workspace + crate, Dart package, lint/test runners)
- [ ] Wire contract — SPEC.md + 19 golden fixtures consumed by BOTH test suites
- [ ] Transport — real TCP + WebSocket accept loop with nodelay + size caps (the "routing" layer of this domain)
- [ ] Auth — real PIN → token → challenge-response flow (the "session" layer)
- [ ] Executor seam — one real input message reaching a mock executor through all gates (the "interactive element" of this domain)
- [ ] Local full-stack run command — `cd server && cargo test --workspace` and `cd app/packages/remote_protocol && dart test` (documented in root README)

## Out of Scope (Deferred to Later Slices)

- Real input injection (enigo), `server-windows` crate — Phase 2
- UDP beacon discovery, reconnect FSM on the phone, secure token storage — Phase 3
- Flutter app scaffold and any UI — Phase 2+ (per D-03 the app scaffold is deferred)
- Config-file persistence of paired tokens (`%APPDATA%` config.toml) — Phase 7; Phase 1 keeps hashes in memory
- Token revoke UI, tray, settings — Phase 7
- TLS/channel binding against live MITM relay — explicitly out of v1 LAN threat model (documented in SPEC security notes)
- PIN-derived token wrapping at pairing — v2 candidate (plaintext-once documented tradeoff)

## Subsequent Slice Plan

Each later phase adds one vertical slice on top of this skeleton without altering its architectural decisions:

- Phase 2: real Windows cursor moves from a bare Dart sender (enigo executor implements the `MouseKeys` trait; <30ms gate)
- Phase 3: discovery + pairing + silent reconnect UX (ConnectionService consumes the same handshake FSM)
- Phase 4: trackpad + keyboard screens (binary frames + key/text messages already contract-locked)
- Phase 5: media/power/presenter/browser (traits + confirm flow already defined)
- Phase 6: apps + clipboard (apps.*/clip.* messages already codec-covered; server push types exist)
- Phase 7: tray shell, settings, revoke (AuthManager grows persistence; wire contract unchanged)
