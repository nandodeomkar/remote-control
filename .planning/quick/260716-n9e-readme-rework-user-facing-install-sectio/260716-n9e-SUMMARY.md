---
phase: quick-260716-n9e
plan: 01
status: complete
subsystem: docs
tags: [readme, distribution, onboarding]
requires: []
provides:
  - "User-facing README install guide (invite -> download -> install -> pair) for the private repo's v1.0.0 Release"
  - "All prior technical README content relocated verbatim under a For developers section"
affects: []
tech-stack:
  added: []
  patterns: []
key-files:
  created: []
  modified: [README.md]
decisions:
  - "Releases linked via GitHub relative form ../../releases/latest (no hardcoded github.com URL) per threat T-n9e-02 mitigation"
  - "APK download instructed ON the phone's browser to skip file transfer between devices"
metrics:
  duration: ~4min
  tasks: 1
  files: 1
  completed: 2026-07-16
---

# Quick Task 260716-n9e: README Rework — User-Facing Install Section Summary

Restructured README.md install-first in plain 8th-grade language so a non-technical friend can go from GitHub invite to a paired phone using only the README, with all prior developer content (monorepo intro, Layout table, Testing section) relocated verbatim under a final For developers heading.

## What Changed

**README.md** (single file, 63 insertions / 3 deletions):

1. **Title + pitch** — kept `# Remote Control`, merged the friendly pitch into two jargon-free sentences; removed the "protocol-first monorepo" sentence from the intro (relocated, not deleted).
2. **`## Install`** (first section) — preamble (two devices, same WiFi, ~5 minutes), invite-acceptance step with the 404-until-accepted note, file-download step naming both release assets exactly (`RemoteControl-Server-v1.0.0.exe`, `RemoteControl-v1.0.0.apk`) with the relative `[Releases page](../../releases/latest)` link and phone-browser download tip, then three sub-sections:
   - `### On your PC` — double-click, SmartScreen "More info" -> "Run anyway", firewall "Allow access", tray-icon success sign (with the ^ arrow hint)
   - `### On your phone` — download on phone, "Install unknown apps" allowance, install and open
   - `### Pair them` — same WiFi, tray pair window QR, Scan QR on phone, 6-digit PIN fallback, auto-reconnect after first pairing
3. **`## What you get`** — 10 plain-language bullets condensed from the DISTRIBUTION.md v1.0 release notes.
4. **`## Troubleshooting`** — three problem/fix pairs: same-WiFi (mobile data won't find it), re-run the .exe for the firewall popup, 60-second QR expiry.
5. **`## For developers`** (last section) — relocated monorepo sentence verbatim, then the old `## Layout` and `## Testing` sections verbatim demoted to `### Layout` / `### Testing`, closing with a link to [DISTRIBUTION.md](DISTRIBUTION.md) for owner build steps.

## Verification

Plan's automated grep gate printed **PASS**:
- First `## ` heading is `## Install`; last is `## For developers`
- All preservation gates present: `cargo test --workspace`, `app/packages/remote_protocol`, `protocol/fixtures/`, `protocol-first monorepo`
- Both release asset filenames and the relative `../../releases/latest` link present; `DISTRIBUTION.md` linked
- Jargon gate: Install section contains none of sideload/binary/artifact/monorepo/fixture (case-insensitive); the words "repo"/"binary"/"artifact" appear only inside For developers

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None — docs-only change, no code touched.

## Commits

| Task | Commit | Message |
|------|--------|---------|
| 1 | 840ed84 | docs(quick-260716-n9e): rework README with user-facing install guide |

## Self-Check: PASSED

- README.md exists on disk with new structure — FOUND
- Commit 840ed84 exists on master — FOUND
