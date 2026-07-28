---
phase: quick-260729-4rg
plan: 01
status: complete
subsystem: server-windows
tags: [windows-subsystem, logging, tracing-appender, ux]
requires: [quick-260729-38z]
provides:
  - "Release binary runs windowed — no console window on any launch path"
  - "Rolling daily log file at %APPDATA%/RemoteControl/logs/server.log.<date>"
  - "Dev builds keep their console and stdout logs"
affects: [diagnostics — the log file replaces the console as the place to look]
tech-stack:
  added: [tracing-appender 0.2]
  patterns: ["cfg_attr(not(debug_assertions), windows_subsystem) — release windowed, dev console"]
key-files:
  created:
    - server/server-windows/src/logging.rs
  modified:
    - server/server-windows/src/main.rs
    - server/server-windows/src/config.rs
    - server/server-windows/src/notify.rs
    - server/server-windows/Cargo.toml
    - DISTRIBUTION.md
decisions:
  - "File sink landed BEFORE hiding the console — hiding it first would have traded a cosmetic annoyance for zero diagnostics"
  - "debug_assertions gate keeps cargo run's console, so development is unchanged"
  - "Unwritable log dir degrades to no file layer, never an error return — same discipline as config::load and machine_guid"
  - "logging::init() is #[must_use]; the WorkerGuard is bound at main scope because dropping it truncates the log tail"
  - "notify.rs's println! calls KEPT and documented as deliberate dev-build output rather than deleted as dead code"
  - "PIN still never reaches tracing (T-03-04) — now more important, since records persist on disk instead of dying with the console"
metrics:
  duration: ~25min
  tasks: 3
  files: 6
  completed: 2026-07-29
---

# Quick Task 260729-4rg — No console window, real log file

## Problem

The server was a console-subsystem exe, so a terminal opened beside the tray
icon on every launch. Tolerable when the only way to start it was running it by
hand out of `server/target/release`; the installer from 260729-38z created three
launch points (Start Menu, desktop icon, autostart), and the window appeared on
all of them. Reported by the owner right after installing v1.3.0.

The one-line fix (`windows_subsystem = "windows"`) also silences stdout — and
stdout was the **only** logging sink. `main.rs:53` built the subscriber with a
bare `tracing_subscriber::fmt()`, and `tracing-appender` was not a dependency at
all, despite the project's stack doc prescribing it ("Spec requires file logging
with level filter"). Hiding the console alone would have swapped a cosmetic
annoyance for zero diagnostics.

## What shipped

**Task 1 — file logging** (`ebb8c1b`)

`logging.rs` assembles the subscriber: a `tracing_appender::rolling::daily`
file layer over `%APPDATA%\RemoteControl\logs`, plus a stdout layer gated on
`debug_assertions`. `config::log_dir()` sits beside `config_path()` so both
known-folder resolutions share one home and one degrade path.

**Task 2 — hide the console** (`564a744`)

`#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]`, plus
corrections to `notify.rs`'s now-false claim that the console print was the
guaranteed path for the pairing PIN.

**Task 3 — docs** (`564a744`)

DISTRIBUTION.md gains the log location, the `RUST_LOG=debug` hint, and the UTC
dating caveat; the uninstall paragraph now mentions logs go with the config.

## Verification

| Check | Result |
|-------|--------|
| `cargo build --release -p server-windows` | Clean, no warnings |
| `cargo test -p server-windows` | 42 passed, 0 failed, 2 ignored |
| PE subsystem field of the release exe | `2` (Windows GUI) — was `3` (Console) |
| Live launch | No terminal; log dir created; `server.log.2026-07-28` written |
| Log contents | `INFO logging to file` + `WARN another instance already holds the instance mutex` |
| Owner's running server | Untouched — the duplicate exited 0 via the mutex |

The live test was free of side effects by construction: `logging::init()` runs
before the single-instance check, so launching the new build against the
already-running installed copy exercised the log file AND the mutex without
disturbing the running server.

## Surprises / notes

- `Option<Layer>` implements `Layer`, which is the clean way to make the stdout
  layer conditional — but a single inferred local cannot be reused across the
  two subscriber shapes (with and without the file layer), because they are
  different `S` types. It has to be a generic function.
- `tracing-appender`'s daily rotation dates files in **UTC**. The first log file
  is `server.log.2026-07-28` despite being written at 03:30 local on the 29th.
  Documented rather than worked around — `rolling` has no local-time option.

## Not done

The published v1.3.0 release does NOT contain this fix; its setup exe was built
before these commits. Re-releasing (1.3.1, or replacing the v1.3.0 asset) is the
owner's call.
