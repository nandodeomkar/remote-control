# Remote Control

An Android app that turns a phone into a wireless mouse, keyboard, and control center for a Windows laptop, paired with a lightweight Windows tray server. The phone controls the laptop over WiFi with zero friction — instant cursor response, full keyboard, and control-center extras (media, power, apps, clipboard, presenter, browser) — all free. This is a protocol-first monorepo: the wire contract in `protocol/` is the source of truth, and both the Rust server and the Dart/Flutter client are tested against the same golden fixtures.

## Layout

| Directory | Contents |
|-----------|----------|
| `protocol/` | Versioned wire spec (`SPEC.md`), JSON schema, and golden fixtures — the shared cross-language contract |
| `server/` | Rust cargo workspace: `server-core` (OS-agnostic protocol/auth/dispatch core) + future `server-windows` binary |
| `app/` | Flutter client; `app/packages/remote_protocol` is the pure Dart protocol package |

## Testing

The local test suites are the CI gate — both must pass before any commit is considered done:

```
cd server && cargo test --workspace
cd app/packages/remote_protocol && dart test
```

The Dart invocation MUST run from the package root (`app/packages/remote_protocol`) — the fixture tests load `protocol/fixtures/` by relative path.

`protocol/fixtures/` is the shared cross-language contract: the Rust and Dart codecs are tested against the same fixture bytes, and no codec may adjust a fixture to match its own output. A dormant GitHub Actions workflow (`.github/workflows/ci.yml`) runs the same two suites and activates automatically if the repo is ever pushed to GitHub.
