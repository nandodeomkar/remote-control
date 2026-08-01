---
phase: quick-260801-rgl
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - .github/workflows/ci.yml
autonomous: true
requirements: [QUICK-260801-RGL]

must_haves:
  truths:
    - "The CI `rust` job builds and tests only `server-core`, never `server-windows`."
    - "The job's own comments state the true invariant (server-core is cross-platform) and record WHY `--workspace` is not used."
    - "`cargo test -p server-core` passes locally with exit 0."
    - "`.github/workflows/ci.yml` is still valid YAML and the `dart` job is untouched."
    - "The file keeps LF line endings and its compact flow-mapping style."
  artifacts:
    - path: ".github/workflows/ci.yml"
      provides: "CI workflow with the rust job scoped to server-core"
      contains: "cargo test -p server-core"
  key_links:
    - from: ".github/workflows/ci.yml (jobs.rust last run step)"
      to: "server/server-core"
      via: "cargo -p package selector"
      pattern: "cargo test -p server-core"
    - from: "server/server-core/Cargo.toml"
      to: "cross-platform dependency set only"
      via: "absence of any windows/GUI crate"
      pattern: "no ^(windows|winreg|enigo|tray-icon|winit|egui|glutin|arboard|auto-launch) dependency line"
---

<objective>
Scope the CI `rust` job to `server-core` so it stops building the Windows-only
`server-windows` crate on an ubuntu runner.

Purpose: the `rust` job has failed 31 of 31 runs since 2026-07-16 — every master
commit and both PR #1 runs are red. `server/Cargo.toml` declares
`members = ["server-core", "server-windows"]`, so `cargo test --workspace` pulls
`server-windows` and its GUI stack (`tray-icon`, `winit`, `egui-winit`,
`egui_glow`, `glutin`) into the build. On Linux those pull `glib-sys`, whose
build script needs GTK dev headers the runner does not have:

    Package glib-2.0 was not found in the pkg-config search path.
    The system library `glib-2.0` required by crate `glib-sys` was not found.

The job's own inline comment says its intent is to prove the zero-Windows-deps
claim by construction — and that claim belongs to `server-core`, whose package
description ends "(zero Windows dependencies)". `--workspace` defeats the very
thing the job exists to prove. Scoping to `-p server-core` makes the job assert
its stated invariant instead of contradicting it.

Output: a one-line change to the `run:` step plus two minimal comment edits in
`.github/workflows/ci.yml`.
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.github/workflows/ci.yml
@server/Cargo.toml
@server/server-core/Cargo.toml
@server/server-windows/Cargo.toml

**Branch discipline (hard constraint):** the executor runs on the CURRENT branch
`gsd/phase-12-wave-1` (the PR branch), with no worktree isolation. Do NOT create,
switch, or delete branches. Do NOT create a worktree. Do NOT `git stash`. Commit
in place.

**Explicitly rejected fix — do not plan or implement it:** installing
`libglib2.0-dev` / `libgtk-3-dev` on the runner. It is slower, and it would still
fail to link the `windows` crate. `server-windows` is a Windows-only binary;
building it on ubuntu proves nothing.

**Do not touch the `dart` job.** It passes.

**Environment facts confirmed at plan time:**
- `.github/workflows/ci.yml` is UTF-8 with LF-only line endings; the repo has no
  `.gitattributes`. Preserve LF.
- PyYAML is importable (`python -c "import yaml"` succeeds). No `actionlint` or
  `yamllint` on PATH — a PyYAML parse plus a semantic assertion is the gate.
- The file's style is terse: compact flow mappings (`with: { workspaces: server }`)
  and short `#` comments. Match it.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Scope the CI rust job to server-core and record why</name>
  <files>.github/workflows/ci.yml</files>
  <action>
Make three edits to the `jobs.rust` block, and only that block.

1. Change the last step from `- run: cargo test --workspace` to
   `- run: cargo test -p server-core`.

2. Tighten the `runs-on:` inline comment so it states what is now actually true.
   Insert `server-core's` — keep the existing padding so the `#` stays in the
   same column:

   `    runs-on: ubuntu-latest          # proves server-core's zero-Windows-deps claim by construction`

3. Add a two-line full-line comment immediately above the `run:` step recording
   WHY the workspace is not tested here, so a future reader does not "helpfully"
   restore `--workspace` and re-break the job. (Line 1 of the file is already a
   full-line comment, so this form is in-voice.)

The `jobs.rust` block must end up exactly:

  rust:
    runs-on: ubuntu-latest          # proves server-core's zero-Windows-deps claim by construction
    defaults: { run: { working-directory: server } }
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
        with: { workspaces: server }
      # scoped, not --workspace: server-windows is a Windows-only binary and its
      # GUI stack (tray-icon/winit/egui/glutin) needs GTK headers no Linux runner has
      - run: cargo test -p server-core

Do not reformat `defaults:` or the `with:` flow mappings. Do not add a
`name:` to any step. Do not reorder steps. Do not edit `jobs.dart`, the top-level
`name:`/`on:` keys, or the file's leading comment. Do not convert the file to
CRLF; keep the trailing newline.

Note on `Swatinem/rust-cache@v2`: leave `workspaces: server` as is. It scopes the
cache to the `server/` workspace directory, which is still correct — it is not a
cargo `--workspace` flag and is unrelated to the defect.

Commit on the current branch (`gsd/phase-12-wave-1`) with:
`fix(ci): scope rust job to server-core so it stops building the Windows GUI stack`
  </action>
  <verify>
    <automated>
Run all four gates from the repo root. All must pass.

G1 — cargo (the local proof, Windows). Expect exit 0; the orchestrator's
baseline run was 164 tests across 6 binaries, 0 failures:

  cargo test --manifest-path "C:/Users/omkar/Projects/Remote Control/server/Cargo.toml" -p server-core

G2 — YAML validity + semantic assertion on the parsed workflow. This is
comment-immune (PyYAML strips `#`), so it cannot be satisfied by comment text
alone. It also pins the `dart` job as unchanged:

  python -c "import yaml; d=yaml.safe_load(open(r'C:/Users/omkar/Projects/Remote Control/.github/workflows/ci.yml')); r=[s['run'] for s in d['jobs']['rust']['steps'] if 'run' in s]; assert r==['cargo test -p server-core'], r; dv=[s['run'] for s in d['jobs']['dart']['steps'] if 'run' in s]; assert dv==['dart pub get','dart analyze --fatal-infos','dart test'], dv; print('ci.yml OK')"

G3 — line endings preserved (LF only, trailing newline intact):

  python -c "d=open(r'C:/Users/omkar/Projects/Remote Control/.github/workflows/ci.yml','rb').read(); assert b'\r' not in d, 'CRLF introduced'; assert d.endswith(b'\n'), 'trailing newline lost'; print('LF OK')"

G4 — the invariant the job now claims is real. Strip comments first (the manifest
mentions "Windows" in prose, so an unfiltered grep would be self-invalidating),
then assert no Windows-only or GUI dependency line exists in server-core:

  sed 's/#.*//' "C:/Users/omkar/Projects/Remote Control/server/server-core/Cargo.toml" | grep -Ei '^[[:space:]]*(windows|winreg|enigo|tray-icon|winit|egui[-_a-z]*|glutin[-a-z]*|arboard|auto-launch|tauri-winrt-notification)[[:space:]]*=' && echo "FAIL: windows/GUI dep in server-core" || echo "PASS: no windows/GUI deps in server-core"

  Pass condition: prints `PASS: ...`. (grep exits 1 on zero matches; that non-zero
  exit is the success path here.)

G5 — blast radius. Exactly one file changed:

  git -C "C:/Users/omkar/Projects/Remote Control" diff --name-only

  Expect exactly: .github/workflows/ci.yml
    </automated>
  </verify>
  <done>
- `.github/workflows/ci.yml` `jobs.rust` last run step is `cargo test -p server-core`
  and the string `--workspace` no longer appears as a cargo flag anywhere in the
  file (it survives only inside the new explanatory comment, by design).
- The `runs-on:` comment names `server-core`; a comment above the run step
  explains why the workspace is not tested.
- G1–G5 all pass.
- `jobs.dart` is byte-identical to before.
- Change committed on `gsd/phase-12-wave-1`; no branch or worktree was created.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| repo → GitHub Actions runner | CI config controls what gets built and asserted on every push and PR |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-RGL-01 | Tampering | `.github/workflows/ci.yml` `jobs.rust` | mitigate | Narrowing CI scope can silently drop real coverage. G2 pins the exact run command AND the untouched `dart` step list; G4 proves the narrowed scope still asserts a real invariant (server-core has zero Windows/GUI deps) rather than being a vacuous green. |
| T-RGL-02 | Denial of Service | CI signal quality | mitigate | A permanently-red job trains reviewers to ignore CI, masking genuine regressions. This change restores a meaningful signal; that is the point of the task. |
| T-RGL-SC | Tampering | npm/pip/cargo installs | accept | No package is added, removed, or version-changed. `server/Cargo.toml`, both member manifests, and `Cargo.lock` are untouched. No supply-chain surface. |
</threat_model>

<verification>
- G1: `cargo test -p server-core` exits 0 on Windows.
- G2: workflow parses as YAML; `jobs.rust` has exactly one run step equal to
  `cargo test -p server-core`; `jobs.dart` run steps unchanged.
- G3: file is still LF-only with a trailing newline.
- G4: `server-core/Cargo.toml` (comments stripped) declares no windows/GUI crate.
- G5: `git diff --name-only` lists only `.github/workflows/ci.yml`.

**Honest limit of local verification.** A `cargo test -p server-core` run on this
Windows machine CANNOT prove the Linux outcome — it exercises a different target
and a different set of pre-built artifacts. The real proof is the `rust` job going
green on the CI run after this is pushed, which is outside this task's scope. Do
not write a SUMMARY claiming the Linux failure is confirmed fixed. The strongest
local evidence available is G4: `server-core`'s manifest contains no Windows-only
and no GUI dependency (tokio, tokio-tungstenite, futures-util, serde, serde_json,
sha2, hmac, rand, subtle, thiserror, hex, if-addrs — every one cross-platform), so
nothing in its dependency graph can reach `glib-sys`. State it that way.
</verification>

<success_criteria>
- The CI `rust` job no longer builds `server-windows`.
- The job asserts the invariant its comment claims, and the file records why
  `--workspace` must not come back.
- `cargo test -p server-core` passes locally, exit 0.
- YAML valid; `dart` job untouched; LF endings and terse style preserved.
- Exactly one file changed, committed on the current branch.
</success_criteria>

<output>
Create `.planning/quick/260801-rgl-scope-the-rust-ci-job-to-server-core/260801-rgl-SUMMARY.md` when done.
</output>
