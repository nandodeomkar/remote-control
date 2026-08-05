# Deferred items — 260805-axr

Out-of-scope discoveries made while executing this plan. **Not fixed here.**

## 1. `cargo clippy` cannot run on the pinned toolchain (pre-existing)

`server/rust-toolchain.toml` pins `1.97.0`, and the `clippy` component is installed
only for `1.89` (the rustup default). So verification step 3
(`cargo clippy -p server-windows --all-targets`) fails with:

```
error: 'cargo-clippy.exe' is not installed for the toolchain '1.97.0-x86_64-pc-windows-msvc'.
```

Falling back to `cargo +1.89 clippy` does not work either — `egui 0.35` and its
`ecolor`/`emath`/`epaint` siblings require rustc 1.92.

Pre-existing, unrelated to this change, and the remedy is a toolchain component
download (`rustup component add clippy --toolchain 1.97.0-x86_64-pc-windows-msvc`),
which this plan is not authorised to perform. Substitute evidence recorded in the
summary: a full `cargo build -p server-windows --all-targets` after touching the
changed file produced **zero rustc warnings**.

## 2. `spawn_helper` passes the script path to `cmd /c` unquoted

`Command::new("cmd.exe").args(["/c", path])` — Rust quotes an argument only when it
contains a space or a quote, so a `%TEMP%` path containing `(`, `)` or `&` and NO
space would end the `cmd` command line early and the helper would never run.

Found the hard way: the Task 2 fixture reused `scratch_dir`, whose name rendered
`ThreadId(13)`, and the real spawn silently did nothing. Fixed **on the test side**
(the scratch name is now digits-only) because the production path is
`%TEMP%\rc-update-<pid>.cmd` and a real `%TEMP%` carrying a paren or ampersand
almost always carries a space too (`C:\Users\John (Work)\...`), which Rust then
quotes correctly.

Residual risk is narrow but real. A fix would be `raw_arg` with explicit quoting,
whose `cmd /c` quote-stripping rules are subtle enough to deserve their own task
rather than a drive-by change to the path this plan is repairing.
