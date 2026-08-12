# Phase 1: Protocol Contract & Server Core - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-07-07
**Phase:** 1-Protocol Contract & Server Core
**Areas discussed:** None (all delegated)

---

## Gray Area Selection

| Option | Description | Selected |
|--------|-------------|----------|
| CI target | No git remote; GitHub Actions vs local test suites as the "proven in CI" gate | |
| Dart codec home | Full Flutter scaffold now vs pure Dart protocol package first | |
| Protocol strictness | Unknown-field policy, minor-version negotiation semantics | |
| Fixture format | Encoding, per-family layout, naming of golden fixtures | |

**User's choice:** "No preference" — no areas selected for discussion.
**Notes:** User delegated all four areas to Claude's discretion. Defaults chosen and locked in CONTEXT.md (D-01..D-09) so downstream agents don't re-litigate.

---

## Claude's Discretion

- CI target: local `cargo test` + `dart test` as the Phase 1 gate; GitHub Actions workflow file written but dormant until repo is pushed
- Dart codec home: pure Dart package (`app/packages/remote_protocol/`), Flutter scaffold deferred to Phase 2
- Protocol strictness: ignore unknown fields, hard-error on missing required fields; protoVersion major.minor, reject major mismatch only; unknown `t` → `err` reply, connection stays alive
- Fixture format: per-family directories, one JSON scenario file each (`NN-scenario-slug.json`) with wire form + expected decoded form

## Deferred Ideas

None.
