//! The hand-off: a detached helper that outlives the server it replaces.
//!
//! One fact the whole design rests on: **the server must die for Inno's
//! `AppMutex` gate to pass.** `installer/RemoteControl.iss` sets
//! `AppMutex=RemoteControl.SingleInstance`, the same name
//! [`crate::single_instance::MUTEX_NAME`] holds for the whole run, and Setup
//! checks it *before* the Preparing-to-Install stage. So the process that
//! knows an update is happening cannot be the process that performs it — only
//! something outside the server can sequence wait, install and relaunch.
//!
//! That something is a `.cmd` written to `%TEMP%` and spawned with
//! [`HELPER_CREATION_FLAGS`] — `CREATE_NO_WINDOW` **alone**, and emphatically
//! NOT `DETACHED_PROCESS | CREATE_NO_WINDOW`, which is not a valid pair and is
//! what wedged the shipped 1.6.0/1.6.1 helper (see [`DETACHED_PROCESS`] for the
//! full account). `.cmd` and not `.ps1` because PowerShell script execution is
//! subject to a machine-configurable `ExecutionPolicy` that can be
//! `Restricted`, and `cmd.exe` has no equivalent gate. The helper is six
//! commands; robustness beats ergonomics.
//!
//! # The correction that supersedes the design spec
//!
//! `/VERYSILENT` **alone does NOT suppress the AppMutex dialog.** Verified
//! from Inno's `Setup.MainFunc.pas`: the check is a suppressible `MB_OKCANCEL`
//! whose suppression is armed only by `/SUPPRESSMSGBOXES` combined with a
//! silent switch. So two belts, both load-bearing:
//!
//! 1. the helper waits for the server PID to exit — a mutex is a kernel object
//!    released on process death, including a hard kill, so PID death is a
//!    sufficient release signal ([`crate::single_instance`] documents this);
//! 2. `/SUPPRESSMSGBOXES` is passed anyway, so a mutex somehow still held
//!    defaults to `IDCANCEL` → `Abort` → a decodable non-zero exit, instead of
//!    parking a modal dialog on the owner's desktop forever (T-12-29).
//!
//! # Failure posture
//!
//! DEGRADE, NEVER CRASH, and every failure collapses to
//! [`UpdateError::Installer`] — paths and OS error strings go to `tracing` and
//! `update.log` only, never to the wire (T-12-06).

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

use super::UpdateError;
use super::download;
use super::marker;

/// **Deliberately NOT used. Never pass this flag from this module again.**
///
/// It is kept only so the reader meets this explanation before the value, and
/// so [`creation_flags_are_the_documented_values`] can assert its ABSENCE from
/// [`HELPER_CREATION_FLAGS`].
///
/// MS "Process Creation Flags" specifies that `CREATE_NO_WINDOW` is **IGNORED
/// when `DETACHED_PROCESS` is set**. The two together therefore left the child
/// `cmd.exe` with no console *at all* rather than with a hidden one — and a
/// console-less `cmd` running a pipeline (`tasklist ... | find ...`) re-spawns
/// itself once per pipe side, so Windows allocated the grandchildren fresh,
/// **VISIBLE** consoles, and `find` then blocked forever on its pipe read.
/// Observed on hardware (12-18 Task 4): a window titled `find "7556"` on the
/// owner's desktop, 0.03 s of CPU across four minutes — blocked, not spinning —
/// so not one poll ever completed, `MAX_WAIT_POLLS` never armed, and Setup
/// never ran. That is the whole of the 1.6.0/1.6.1 self-update defect.
///
/// Helper survival never depended on this flag: Windows has no parent-child
/// process lifetime link, and `std::process::Child` has no kill-on-drop, which
/// is what [`spawn_helper`]'s own doc comment already said. The pipe is gone
/// too (see [`HELPER_TEMPLATE`]'s `:wait` block), but both halves stay fixed —
/// neither one alone should be trusted to keep this path working.
#[allow(dead_code, reason = "kept as documentation and asserted against by tests")]
const DETACHED_PROCESS: u32 = 0x0000_0008;
/// (MS "Process Creation Flags") — the child gets its own console which is
/// never displayed. That is the property that matters: any console-application
/// grandchild inherits this invisible console instead of having a fresh,
/// visible one allocated for it.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The flags [`spawn_helper`] passes: `CREATE_NO_WINDOW` **alone**.
///
/// Named rather than inlined so a test can assert both what it is and — the
/// assertion that matters — that [`DETACHED_PROCESS`] is not part of it.
const HELPER_CREATION_FLAGS: u32 = CREATE_NO_WINDOW;

/// The installed exe's fixed name, shared VERBATIM with the installer.
///
/// `installer/RemoteControl.iss` defines `MyAppExeName "RemoteControl.exe"`
/// and renames the build output to it via `DestName`, so the running process
/// IS `{app}\RemoteControl.exe`. Changing this string on one side only would
/// leave the helper relaunching a path that does not exist — change both or
/// neither.
const INSTALLED_EXE_NAME: &str = "RemoteControl.exe";

/// Placeholder tokens in [`HELPER_TEMPLATE`], substituted by
/// [`helper_script`]. The `__NAME__` shape exists so a missed substitution is
/// greppable and testable rather than silently shipping a literal into a
/// command line.
const P_PID: &str = "__PID__";
const P_SETUP: &str = "__SETUP__";
const P_EXE: &str = "__EXE__";
const P_MARKER: &str = "__MARKER__";
const P_LOG: &str = "__LOG__";
const P_TARGET: &str = "__TARGET__";

/// Bound on the PID wait, in polls of roughly one second each (T-12-28).
const MAX_WAIT_POLLS: u32 = 30;

/// The helper text, with every substituted value quoted.
///
/// The `set "NAME=VALUE"` idiom is deliberate: the quotes delimit the
/// *assignment*, so they do not enter the value, and a value containing a
/// space, an `&` or a `|` cannot end the command. Use sites then quote the
/// expansion (`"%SETUP%"`).
const HELPER_TEMPLATE: &str = r#"@echo off
REM Generated by server-windows update::apply::helper_script for one attempt.
REM Do not edit: it is rewritten every time and deletes itself on the way out.
REM
REM WHY IT EXISTS: the server must EXIT for Inno's
REM AppMutex=RemoteControl.SingleInstance gate to pass, so the process that
REM knows an update is happening cannot be the process that performs it.
setlocal

REM Every value is quoted with the set "NAME=VALUE" idiom (the quotes delimit
REM the assignment and never enter the value). TARGET has already been
REM validated as ^\d+\.\d+\.\d+$ by the caller and debug-asserted again in
REM helper_script - an unvalidated value here is a cmd injection (T-12-26).
set "PID=__PID__"
set "SETUP=__SETUP__"
set "EXE=__EXE__"
set "MARKER=__MARKER__"
set "LOG=__LOG__"
set "TARGET=__TARGET__"

REM 1. Wait until the server's own exe is WRITABLE, which is the same event
REM    that releases the AppMutex Setup checks: a running process holds a write
REM    lock on its own image (Windows shares only READ and DELETE on a mapped
REM    image), so a successful append means that process is gone and its mutex
REM    handle with it. It is at least as strong a gate as PID death and
REM    strictly stronger against a third party holding the file - and it tests
REM    exactly what Setup needs, that {app}\RemoteControl.exe is replaceable.
REM
REM    The check is deliberately PIPE-FREE and spawns NO child process. The
REM    check it replaces was a tasklist piped into find, and that pipeline is
REM    what wedged the shipped 1.6.0/1.6.1 helper: cmd re-spawns itself once per
REM    pipe side and find then blocked forever on its pipe read, so not one poll
REM    ever completed.
REM
REM    The if-not-exist line is a guard, not an optimisation: an append
REM    redirection to a MISSING file CREATES it, and EXE degrades to the bare
REM    name RemoteControl.exe when current_exe fails, which would otherwise
REM    conjure a stray file into this script's working directory. If the exe is
REM    genuinely absent there is nothing to wait for and nothing to protect.
REM    The call with a trailing space is the no-op that sets ERRORLEVEL 0, so
REM    the conditional runs only when the redirection itself succeeded - and
REM    the append writes ZERO bytes, so the exe's contents cannot change.
REM
REM    The sleep is `ping` and deliberately NOT the timeout command: timeout
REM    reads stdin, and this child's stdin is NUL.
set /a N=0
:wait
if not exist "%EXE%" goto gone
2>nul (
  >>"%EXE%" (call )
) && goto gone
set /a N+=1
REM    Bounded (T-12-28): an exe that stays locked must not leave this helper
REM    polling forever, and firing the install into a held mutex would abort
REM    anyway. So the INSTALL is skipped on timeout - but the RELAUNCH is NOT.
REM    The shipped helper jumped straight to the cleanup label, PAST the
REM    relaunch, so a timeout for ANY reason - including a stuck lock held by
REM    something that is not the server - left the owner with no server running
REM    at all, the exact outcome this bound exists to prevent. Routing through
REM    :relaunch also reaches the cleanup label, which is what deletes the
REM    leaked setup exe on the abort path.
REM    Accepted cost: if the server really is still alive, the relaunch is
REM    refused by the single-instance mutex and the owner sees the "already
REM    running" toast. Strictly better than no server.
if %N% GEQ __MAX_POLLS__ (
  echo [%DATE% %TIME%] server exe still locked after __MAX_POLLS__ polls, pid %PID%; skipping the install and relaunching >> "%LOG%"
  goto relaunch
)
ping -n 2 127.0.0.1 >nul
goto wait
:gone

REM 2. /SUPPRESSMSGBOXES is MANDATORY, not decoration: /VERYSILENT alone does
REM    not arm suppression of Inno's AppMutex MB_OKCANCEL, and that check runs
REM    before the CloseApplications stage. /LOG makes an installer failure
REM    diagnosable at all.
"%SETUP%" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG="%TEMP%\rc-setup.log"

REM 3. Non-zero exit (D-24): append one line and jump straight to the
REM    relaunch, leaving the marker exactly as the server wrote it - a failed
REM    install must stay reported as a failed install.
if errorlevel 1 (
  echo [%DATE% %TIME%] setup exited %ERRORLEVEL% installing %TARGET% >> "%LOG%"
  goto relaunch
)

REM 4. Zero exit ONLY - promote the pessimistic marker to success (D-16).
> "%MARKER%" echo {"target":"%TARGET%","ok":true}

:relaunch
REM 5. [Run] in RemoteControl.iss carries skipifsilent, so Setup does NOT
REM    start the app under a silent install. The relaunch is unconditional:
REM    after a failure the OLD exe is still installed and still works.
start "" "%EXE%"

:end
del "%SETUP%" 2>nul
endlocal
REM Standard cmd self-delete: (goto) 2>nul closes the batch context so the
REM file is no longer locked, then del removes it.
(goto) 2>nul & del "%~f0"
"#;

/// Build the helper `.cmd` text. PURE — no disk, no process, no clock — so it
/// can be golden-tested in full (the `clip_thread::should_skip_clip`
/// factoring rule).
///
/// # The target is the only wire-influenced value
///
/// `target` has ALREADY been checked against `^\d+\.\d+\.\d+$` by the caller
/// ([`super::download::is_valid_target`]); the debug assertion below is a
/// second tripwire, not the defence. It matters because this value is
/// interpolated into a command line: a payload carrying `"` and `&` would be
/// straightforward command injection with the owner's privileges (T-12-26).
///
/// The paths are all server-chosen and never wire-derived (D-14), but they are
/// asserted too — a quote is not a legal Windows path character, so one
/// appearing here means something upstream is wrong.
pub fn helper_script(
    pid: u32,
    setup: &Path,
    installed_exe: &Path,
    marker: &Path,
    log: &Path,
    target: &str,
) -> String {
    debug_assert!(
        super::download::is_valid_target(target),
        "helper_script called with an unvalidated target: {target:?} — \
         the caller must enforce ^\\d+\\.\\d+\\.\\d+$ first (T-12-26)"
    );

    let setup = setup.to_string_lossy();
    let installed_exe = installed_exe.to_string_lossy();
    let marker = marker.to_string_lossy();
    let log = log.to_string_lossy();
    for p in [&setup, &installed_exe, &marker, &log] {
        debug_assert!(
            !p.contains('"') && !p.contains('\n') && !p.contains('\r') && !p.contains('%'),
            "a helper path carries a cmd metacharacter: {p:?}"
        );
    }

    let max_polls = MAX_WAIT_POLLS.to_string();
    let text = HELPER_TEMPLATE
        .replace("__MAX_POLLS__", &max_polls)
        .replace(P_PID, &pid.to_string())
        .replace(P_SETUP, &setup)
        .replace(P_EXE, &installed_exe)
        .replace(P_MARKER, &marker)
        .replace(P_LOG, &log)
        .replace(P_TARGET, target);

    // CRLF: cmd.exe's block parsing (the `if (...)` arms above) is only
    // reliably specified for CRLF batch files, and every value substituted
    // above is asserted newline-free, so this rewrite cannot corrupt one.
    text.replace('\n', "\r\n")
}

/// The exe the helper must relaunch: `{app}\RemoteControl.exe`, resolved from
/// the PARENT of `current_exe()` rather than from `current_exe()` itself.
///
/// The two are the same path today — the installer renames the build output
/// via `DestName`, so the running process already is `{app}\RemoteControl.exe`
/// — but relying on that is fragile. Rebuilding from the directory plus the
/// installer's fixed name keeps the relaunch correct if the exe is ever run
/// from a differently-named copy, and it is the same directory the HKCU `Run`
/// value points at.
///
/// Degrades rather than panics: an unresolvable `current_exe()` yields the
/// bare name, which `start ""` resolves through the helper's search path. A
/// failed relaunch is a disappointing update, not a crashed server.
pub fn installed_exe() -> PathBuf {
    match std::env::current_exe() {
        Ok(p) => p
            .parent()
            .map_or_else(|| PathBuf::from(INSTALLED_EXE_NAME), |d| d.join(INSTALLED_EXE_NAME)),
        Err(e) => {
            tracing::warn!(
                "update: could not resolve the current exe ({}); the helper will \
                 relaunch by name only",
                e.kind()
            );
            PathBuf::from(INSTALLED_EXE_NAME)
        }
    }
}

/// The helper script's filename parts, factored out of [`helper_script_path`]
/// for the same anti-drift reason as [`download::SETUP_FILE_PREFIX`]:
/// [`sweep_temp_orphans_in`] matches on THESE, never on a re-typed literal.
const HELPER_SCRIPT_PREFIX: &str = "rc-update-";
const HELPER_SCRIPT_SUFFIX: &str = ".cmd";

/// `%TEMP%\rc-update-<pid>.cmd` — the helper's own path.
///
/// Per-PID so two attempts (or a stale file from a previous run) can never
/// share one script, and under `%TEMP%` because that is where a self-deleting
/// throwaway belongs. T-12-30 accepts the residual: a local process able to
/// rewrite `%TEMP%` between the write and the spawn already owns the machine.
pub fn helper_script_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "{HELPER_SCRIPT_PREFIX}{}{HELPER_SCRIPT_SUFFIX}",
        std::process::id()
    ))
}

/// How old a `%TEMP%` leftover must be before [`sweep_temp_orphans`] removes it.
///
/// The ONLY thing an age guard protects is a helper from a PREVIOUS process
/// that is still counting down its bounded wait — and that wait cannot exceed
/// [`MAX_WAIT_POLLS`] roughly-one-second polls, about 30 seconds. An hour is
/// therefore enormously generous, while the leftovers this exists to clear are
/// hours or days old.
///
/// Nothing in the CURRENT process can be at risk either: the sweep runs once at
/// startup, and this process's own script and setup exe are not created until
/// the owner asks for an update, long afterwards.
const MIN_ORPHAN_AGE: Duration = Duration::from_secs(60 * 60);

/// Remove the `%TEMP%` files a wedged update attempt leaked.
///
/// Both `del "%SETUP%"` and the script's self-delete sit at the helper's `:end`
/// label, which a wedged run never reaches — so every wedged attempt on
/// 1.6.0/1.6.1 left `%TEMP%\rc-update-<pid>.cmd` plus a ~5.9 MB setup exe
/// behind, and fixing the wedge does not retroactively remove them. Every
/// machine that ran either version is already carrying orphans.
///
/// Failure posture is [`marker::truncate_update_log_if_large`]'s: an
/// unsweepable `%TEMP%` is not a reason to do anything differently.
pub fn sweep_temp_orphans() {
    let _ = sweep_temp_orphans_in(
        &std::env::temp_dir(),
        &helper_script_path(),
        MIN_ORPHAN_AGE,
    );
}

/// [`sweep_temp_orphans`] with the directory, this process's own script and the
/// age threshold injected — the `_at`/`_with` convention this module already
/// uses ([`marker::write_pending_at`], [`begin_apply_with`]) — so no test ever
/// sweeps the real `%TEMP%`.
///
/// Returns the number of files removed, so the log line and the tests can both
/// assert it.
fn sweep_temp_orphans_in(dir: &Path, own_script: &Path, min_age: Duration) -> u32 {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        // Debug, never warn: this is housekeeping, and a `%TEMP%` that cannot
        // be listed changes nothing about the server's job.
        Err(e) => {
            tracing::debug!("update: could not scan the temp directory ({})", e.kind());
            return 0;
        }
    };

    let own_name = own_script.file_name();
    let now = SystemTime::now();
    let mut removed: u32 = 0;

    for entry in entries.flatten() {
        let raw_name = entry.file_name();
        let Some(name) = raw_name.to_str() else {
            continue;
        };

        // Anchored on BOTH ends, and built from the writers' own constants.
        let is_helper =
            name.starts_with(HELPER_SCRIPT_PREFIX) && name.ends_with(HELPER_SCRIPT_SUFFIX);
        let is_setup = name.starts_with(download::SETUP_FILE_PREFIX)
            && name.ends_with(download::SETUP_FILE_SUFFIX);
        if !is_helper && !is_setup {
            continue;
        }

        // The PID guard, expressed against the writer's own path rather than by
        // re-deriving the PID: this process's own script is never a candidate.
        if own_name.is_some_and(|own| own == raw_name.as_os_str()) {
            continue;
        }

        // Directories are never touched, whatever they are called.
        let Ok(md) = entry.metadata() else {
            continue;
        };
        if !md.is_file() {
            continue;
        }

        // An unreadable timestamp, or one in the future, counts as FRESH — the
        // safe direction, since the cost of skipping is one more startup.
        let is_fresh = md
            .modified()
            .ok()
            .and_then(|m| now.duration_since(m).ok())
            .is_none_or(|age| age < min_age);
        if is_fresh {
            continue;
        }

        if let Err(e) = std::fs::remove_file(entry.path()) {
            // A file another process still holds open simply stays; the next
            // startup gets it. Never retried here.
            tracing::debug!("update: could not remove a stale temp file ({})", e.kind());
            continue;
        }
        removed += 1;
    }

    // Counts and error kinds only — never a path (T-12-06).
    if removed > 0 {
        tracing::info!("update: removed {removed} stale update file(s) from the temp directory");
    }
    removed
}

/// Spawn the helper and walk away.
///
/// Three deliberate choices:
/// - [`HELPER_CREATION_FLAGS`] — `CREATE_NO_WINDOW` **alone**, so the child
///   gets its OWN console which is never displayed, and any console-app
///   grandchild inherits that invisible console instead of having a fresh,
///   visible one allocated for it. `DETACHED_PROCESS` is NOT passed and must
///   never be re-added: MS "Process Creation Flags" makes `CREATE_NO_WINDOW`
///   ignored when it is set, which left the shipped 1.6.0/1.6.1 helper with no
///   console at all and wedged it (the full account is on
///   [`DETACHED_PROCESS`]). Nothing about the child's survival ever depended on
///   that flag — see the third bullet, which is the actual mechanism;
/// - all three stdio handles null — an inherited handle would keep this
///   process's pipes alive and can block the child's writes;
/// - **the child is never waited on.** This process is about to exit, and
///   `std::process::Child`
///   has no `Drop` impl that kills the child, so simply dropping it is what
///   lets the helper outlive us. Waiting would deadlock the very sequence the
///   helper exists to perform: it is waiting for us to die.
fn spawn_helper(script: &Path) -> std::io::Result<()> {
    Command::new("cmd.exe")
        .args(["/c", &script.to_string_lossy()])
        .creation_flags(HELPER_CREATION_FLAGS)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    Ok(())
}

/// Sequence the hand-off: pessimistic marker, helper script, detached spawn.
///
/// Called ONLY after [`super::download::verify_or_delete`] has succeeded —
/// unverified bytes must never reach this function (T-12-27), and by the time
/// that function returns an error the file is already gone.
///
/// # This function does NOT exit the process
///
/// Deliberately. The caller owns the exit so it can publish a final
/// `update.progress {stage:"restarting"}` first and give the phone a chance to
/// render it before the socket drops. An `exit` here would race that frame off
/// the wire and leave the phone staring at `installing` until its reconnect
/// FSM gave up (D-25).
///
/// # Errors
///
/// Every failure — a script that cannot be written, a `cmd.exe` that cannot be
/// spawned — collapses to [`UpdateError::Installer`]. The underlying error is
/// logged and dropped: the closed D-11 vocabulary is what reaches the wire,
/// and an OS error string carrying a path is exactly what must not (T-12-06).
pub fn begin_apply(target: &str, setup_path: &Path) -> Result<(), UpdateError> {
    begin_apply_with(
        target,
        setup_path,
        &marker::marker_path(),
        &marker::update_log_path(),
        &helper_script_path(),
        &installed_exe(),
        spawn_helper,
    )
}

/// [`begin_apply`] with every path and the spawn itself injected, so the
/// sequencing can be tested without touching `%APPDATA%` and — the part that
/// matters — without starting a detached process that installs software.
#[allow(clippy::too_many_arguments)]
fn begin_apply_with(
    target: &str,
    setup_path: &Path,
    marker_path: &Path,
    log_path: &Path,
    script_path: &Path,
    exe_path: &Path,
    spawn: impl Fn(&Path) -> std::io::Result<()>,
) -> Result<(), UpdateError> {
    // 1. PESSIMISTIC FIRST (D-16). From here on every way this process can die
    //    — including ways that never reach line 2 — leaves an honest record,
    //    and only the helper observing a zero exit code can improve it.
    marker::write_pending_at(marker_path, target);

    // 2. The script text is pure and validates the target again on the way in.
    let text = helper_script(
        std::process::id(),
        setup_path,
        exe_path,
        marker_path,
        log_path,
        target,
    );
    if let Err(e) = std::fs::write(script_path, text) {
        tracing::error!("update: could not write the helper script ({})", e.kind());
        return Err(UpdateError::Installer);
    }

    // 3. Hand off. After this returns Ok the helper is already polling for our
    //    PID to disappear.
    if let Err(e) = spawn(script_path) {
        tracing::error!("update: could not spawn the update helper ({})", e.kind());
        let _ = std::fs::remove_file(script_path);
        return Err(UpdateError::Installer);
    }

    tracing::info!("update: helper spawned; exiting to let the installer replace this exe");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> String {
        helper_script(
            4242,
            &PathBuf::from("C:\\Temp\\RemoteControl-Setup-v1.6.0.exe"),
            &PathBuf::from("C:\\Program Files\\Remote Control\\RemoteControl.exe"),
            &PathBuf::from("C:\\Users\\o\\AppData\\Roaming\\RemoteControl\\update-result.json"),
            &PathBuf::from("C:\\Users\\o\\AppData\\Roaming\\RemoteControl\\logs\\update.log"),
            "1.6.0",
        )
    }

    /// The golden assertion: every requirement of Pattern 3 is present in the
    /// generated text, and nothing that would break a detached child is.
    #[test]
    fn helper_script_text() {
        let s = sample();

        // No placeholder survives substitution.
        assert!(
            !s.contains("__"),
            "an unsubstituted placeholder survived:\n{s}"
        );

        // Every substituted value landed.
        assert!(s.contains("set \"PID=4242\""));
        assert!(s.contains("set \"SETUP=C:\\Temp\\RemoteControl-Setup-v1.6.0.exe\""));
        assert!(s.contains("set \"EXE=C:\\Program Files\\Remote Control\\RemoteControl.exe\""));
        assert!(s.contains("set \"TARGET=1.6.0\""));

        // The mandatory installer switches (the objective's correction).
        assert!(s.contains("/VERYSILENT"));
        assert!(s.contains("/NORESTART"));
        assert!(
            s.contains("/SUPPRESSMSGBOXES"),
            "/SUPPRESSMSGBOXES is mandatory: /VERYSILENT alone does not arm \
             suppression of Inno's AppMutex MB_OKCANCEL"
        );
        assert!(s.contains("/LOG="), "an installer failure must be diagnosable");

        // The bounded wait. The load-bearing assertion is the ABSENCE of a
        // pipe: a pipeline makes cmd re-spawn itself per side, which is what
        // wedged the shipped 1.6.0/1.6.1 helper (see DETACHED_PROCESS).
        assert!(
            !s.contains('|'),
            "the helper must contain NO pipe anywhere: a pipeline makes cmd \
             re-spawn itself per side, which is the 1.6.0/1.6.1 wedge. If this \
             fires on a REM comment, reword the comment — the assertion is the \
             point:\n{s}"
        );
        assert!(
            s.contains("if not exist \"%EXE%\" goto gone"),
            "an append to a MISSING file would CREATE it; the guard is required"
        );
        assert!(
            s.contains(">>\"%EXE%\" (call )"),
            "the wait is the zero-child-process exe-lock test (D-B)"
        );
        assert!(
            s.contains(") && goto gone"),
            "the lock test proceeds only when the append itself succeeded"
        );
        assert!(s.contains("ping -n 2 127.0.0.1"));
        assert!(
            !s.contains("timeout /t"),
            "timeout reads stdin and this child's stdin is NUL"
        );
        assert!(s.contains(&format!("if %N% GEQ {MAX_WAIT_POLLS}")));

        // The unconditional relaunch ([Run] carries skipifsilent).
        assert!(s.contains("start \"\" \"%EXE%\""));

        // Self-cleanup.
        assert!(s.contains("del \"%SETUP%\""));
        assert!(s.contains("(goto) 2>nul & del \"%~f0\""));

        // cmd batch files are CRLF.
        assert!(s.contains("\r\n"));
        assert!(!s.contains("\n\n"), "a bare LF survived the CRLF rewrite");
    }

    /// The ok:true rewrite happens once, and ONLY on the zero-exit path: it
    /// must sit after the `goto relaunch` a non-zero exit takes and before the
    /// `:relaunch` label that path lands on (D-24).
    #[test]
    fn the_success_rewrite_is_unreachable_from_the_failure_path() {
        let s = sample();

        // The version is written through the `%TARGET%` expansion rather than
        // interpolated a second time — one substitution site, one thing to
        // validate.
        let rewrite = "> \"%MARKER%\" echo {\"target\":\"%TARGET%\",\"ok\":true}";
        assert_eq!(
            s.matches(rewrite).count(),
            1,
            "the marker is promoted to success exactly once"
        );
        assert_eq!(
            s.matches("\"ok\":true").count(),
            1,
            "no second ok:true write may exist anywhere in the script"
        );

        // There are now TWO `goto relaunch` jumps — the wait timeout's and this
        // one — so the failure branch's is located from its own log line rather
        // than by taking the first occurrence in the file.
        let log_line = s.find("setup exited %ERRORLEVEL%").expect("failure logged");
        let jump = log_line
            + s[log_line..]
                .find("goto relaunch")
                .expect("the failure path jumps");
        let promote = s.find(rewrite).expect("the promotion exists");
        let label = s.find("\r\n:relaunch").expect("the relaunch label exists");
        assert!(
            jump < promote && promote < label,
            "the ok:true rewrite must be skipped by the non-zero-exit jump"
        );

        // And the failure path logs before it jumps (D-24).
        assert!(log_line < jump);
    }

    /// The timeout path leaves the marker alone and never reaches the setup
    /// invocation — but it DOES reach the relaunch. Both halves are asserted
    /// because the shipped helper only had the first: it jumped to `:end`,
    /// past the relaunch, so a timeout left the owner with no server at all.
    #[test]
    fn the_wait_timeout_skips_the_installer_but_still_relaunches() {
        let s = sample();
        let timeout_log = s
            .find("skipping the install and relaunching")
            .expect("timeout logged");
        let setup_call = s.find("\"%SETUP%\" /VERYSILENT").expect("setup invoked");
        assert!(
            timeout_log < setup_call,
            "the timeout branch precedes the install and jumps past it"
        );

        // The jump target on the line after the timeout log is `relaunch`, not
        // the cleanup label — this is the half the shipped helper got wrong.
        let after_log = &s[timeout_log..];
        let jump = after_log.find("goto ").expect("the timeout branch jumps");
        assert!(
            after_log[jump..].starts_with("goto relaunch"),
            "the timeout must jump to :relaunch so the old server comes back"
        );
        assert!(
            !s.contains("goto end"),
            "REGRESSION PIN: nothing may ever jump past the relaunch again. A \
             `goto end` is the shipped 1.6.0/1.6.1 defect — a wait timeout that \
             leaves the owner with no server running."
        );

        // `:end` itself stays: it is where the leaked setup exe is deleted, and
        // the relaunch falls through into it.
        let relaunch = s.find("start \"\" \"%EXE%\"").expect("the relaunch exists");
        let end_label = s.find("\r\n:end\r\n").expect("the cleanup label exists");
        assert!(
            relaunch < end_label,
            ":end must sit AFTER the relaunch, so reaching it relaunches first"
        );
    }

    /// A target carrying `cmd` metacharacters is refused before it can be
    /// interpolated. In debug builds — which is where the tests run — the
    /// tripwire is a panic, so `calc` never reaches a script at all.
    #[test]
    #[should_panic(expected = "unvalidated target")]
    #[cfg(debug_assertions)]
    fn helper_script_refuses_an_injecting_target() {
        let _ = helper_script(
            1,
            Path::new("C:\\s.exe"),
            Path::new("C:\\e.exe"),
            Path::new("C:\\m.json"),
            Path::new("C:\\l.log"),
            "1.5.0\" & calc &",
        );
    }

    /// The same refusal for the traversal shape, and a positive control: the
    /// only accepted form is three numeric components.
    #[test]
    #[should_panic(expected = "unvalidated target")]
    #[cfg(debug_assertions)]
    fn helper_script_refuses_a_traversal_target() {
        let _ = helper_script(
            1,
            Path::new("C:\\s.exe"),
            Path::new("C:\\e.exe"),
            Path::new("C:\\m.json"),
            Path::new("C:\\l.log"),
            "..\\..\\Startup\\x",
        );
    }

    /// Whatever a rejected target would have carried, no accepted target can
    /// introduce a command separator: the generated text's only `&` is the
    /// self-delete idiom.
    #[test]
    fn an_accepted_target_introduces_no_command_separator() {
        let s = helper_script(
            7,
            Path::new("C:\\s.exe"),
            Path::new("C:\\e.exe"),
            Path::new("C:\\m.json"),
            Path::new("C:\\l.log"),
            "10.20.30",
        );
        assert!(!s.contains("calc"));
        assert_eq!(
            s.matches(" & ").count(),
            1,
            "the only command separator is the self-delete idiom"
        );
        assert!(s.contains("set \"TARGET=10.20.30\""));
    }

    /// A unique scratch directory per test — the suite runs threaded.
    ///
    /// The thread id is reduced to its digits rather than used as `{:?}`
    /// renders it: `ThreadId(13)` carries `cmd` metacharacters, and the
    /// real-spawn tests below hand this path to `cmd.exe /c`. `Command` quotes
    /// an argument only when it contains a space or a quote, so an unquoted
    /// `(` would end the command line and the helper would never run.
    fn scratch_dir(tag: &str) -> PathBuf {
        let raw = format!("{:?}", std::thread::current().id());
        let tid: String = raw.chars().filter(char::is_ascii_digit).collect();
        let dir = std::env::temp_dir().join(format!(
            "rc-apply-test-{}-{tag}-{tid}",
            std::process::id(),
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create scratch dir");
        dir
    }

    /// Everything a REAL `spawn_helper` run needs on disk.
    ///
    /// The two tests below are the only ones that execute [`spawn_helper`] —
    /// the one function in this path that no test used to run, which is exactly
    /// the seam the shipped 1.6.0/1.6.1 wedge lived behind.
    ///
    /// Three fixture choices are load-bearing:
    ///
    /// - **`stub-exe.cmd` is a `.cmd`.** `start "" "%EXE%"` has ShellExecute
    ///   semantics and always SPAWNS, so a batch file is a fine relaunch
    ///   target. It briefly FLASHES A CONSOLE WINDOW when it fires. That is the
    ///   honest price of covering this seam, and it is far cheaper than the
    ///   shipped defect it catches.
    /// - **`stub-setup.exe` is deliberately NOT a valid PE.** `cmd` therefore
    ///   cannot execute it and `if errorlevel 1` fires deterministically. The
    ///   zero-exit branch is NOT covered here on purpose (D-D): the setup
    ///   invocation carries no `call`, so a `.cmd` stub would CHAIN and the
    ///   helper's remaining lines would never run, and no stock console exe
    ///   exits 0 when handed `/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG=`.
    ///   The `ok:true` rewrite stays pinned by the golden text test plus
    ///   `marker::tests::helper_written_success_marker_parses_without_an_error_field`,
    ///   which parses the exact bytes the `echo` emits.
    /// - **the marker starts pessimistic**, written through the real
    ///   `marker::write_pending_at`, so the helper begins from the exact state
    ///   `begin_apply_with` leaves behind.
    struct HelperFixture {
        dir: PathBuf,
        script: PathBuf,
        setup: PathBuf,
        exe: PathBuf,
        marker: PathBuf,
        log: PathBuf,
        relaunched: PathBuf,
    }

    fn helper_fixture(tag: &str) -> HelperFixture {
        let dir = scratch_dir(tag);

        // The relaunch target. `%~dp0` already ends in a backslash.
        //
        // The trailing `exit` is REQUIRED and is not `exit /b`: `start` launches
        // a batch target through `cmd /K`, which keeps the console — and the
        // process — alive after the script ends. Without it every run of these
        // two tests leaves a live `cmd.exe` and an open console window on the
        // desktop. A bare `exit` ends the `cmd` itself.
        //
        // It shares ONE LINE with the write, deliberately: `cmd` reads a batch
        // file line by line, re-opening it each time, so an `exit` on its own
        // line can be lost when the test removes this directory the moment
        // `relaunched.txt` appears — leaving exactly the orphan the `exit` is
        // there to prevent. On one line the `exit` is already in hand.
        let exe = dir.join("stub-exe.cmd");
        std::fs::write(
            &exe,
            "@echo off\r\n> \"%~dp0relaunched.txt\" echo relaunched & exit\r\n",
        )
        .expect("write stub exe");

        let setup = dir.join("stub-setup.exe");
        std::fs::write(&setup, b"this is not a PE").expect("write stub setup");

        let marker = dir.join("update-result.json");
        marker::write_pending_at(&marker, "1.6.0");

        let log = dir.join("update.log");
        let script = dir.join("rc-update-test.cmd");

        // The PID reaches the timeout LOG LINE and nothing else — the wait is
        // now the exe-lock test, so this test is NOT waiting on itself.
        let text = helper_script(std::process::id(), &setup, &exe, &marker, &log, "1.6.0");
        std::fs::write(&script, text).expect("write helper script");

        HelperFixture {
            relaunched: dir.join("relaunched.txt"),
            dir,
            script,
            setup,
            exe,
            marker,
            log,
        }
    }

    /// The hard deadline that makes running a real spawn by default SAFE: if
    /// the helper ever wedges again this returns `false` and the test fails
    /// with a message that names the wedge, instead of hanging the suite (D-E).
    fn poll_until(deadline: std::time::Duration, mut done: impl FnMut() -> bool) -> bool {
        let start = std::time::Instant::now();
        loop {
            if done() {
                return true;
            }
            if start.elapsed() >= deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    }

    const SPAWN_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);

    /// The test that would have caught the shipped defect: a REAL
    /// [`spawn_helper`] against a REAL generated script, asserted on disk.
    ///
    /// Nothing holds a lock on `stub-exe.cmd`, so the first poll's append
    /// succeeds and the helper falls straight through `:gone`. Every assertion
    /// below is something the wedge prevented.
    #[test]
    fn spawn_helper_runs_the_whole_helper_to_completion() {
        let f = helper_fixture("realspawn");

        spawn_helper(&f.script).expect("the helper must spawn");

        let finished = poll_until(SPAWN_DEADLINE, || !f.script.exists());
        assert!(
            finished,
            "the helper never reached its self-delete within {SPAWN_DEADLINE:?}. \
             THIS IS THE 1.6.0/1.6.1 WEDGE: check the creation flags \
             (DETACHED_PROCESS must NOT be set) and that the script contains no \
             pipe. A stray console window on the desktop is the same symptom."
        );

        assert!(
            !f.setup.exists(),
            "`del \"%SETUP%\"` at :end must remove the downloaded installer"
        );

        let log = std::fs::read_to_string(&f.log).expect("the helper must have written update.log");
        assert!(
            log.contains("setup exited"),
            "Setup must actually be INVOKED — that is the single thing the wedge \
             prevented. update.log said:\n{log}"
        );

        let marker = std::fs::read_to_string(&f.marker).expect("the marker must survive");
        assert!(
            marker.contains("\"ok\":false"),
            "a non-zero installer exit must leave the marker honest (D-24); got:\n{marker}"
        );

        // `start` returns before the spawned stub has written, so this gets its
        // own short deadline rather than being asserted immediately.
        assert!(
            poll_until(std::time::Duration::from_secs(10), || f.relaunched.exists()),
            "the relaunch must fire even after a failed install — the old exe is \
             still installed and still works"
        );

        let _ = std::fs::remove_dir_all(&f.dir);
    }

    /// The regression test for the wait ITSELF: it must actually loop while the
    /// exe is locked, which the golden text test cannot prove.
    ///
    /// `share_mode(0)` denies all sharing, which is how a running server's own
    /// image behaves against an append — so the helper's `>>"%EXE%" (call )`
    /// fails exactly as it does in production, and cannot proceed until the
    /// handle is dropped.
    #[test]
    fn spawn_helper_waits_while_the_exe_is_locked() {
        use std::os::windows::fs::OpenOptionsExt;

        let f = helper_fixture("realwait");

        let lock = std::fs::OpenOptions::new()
            .write(true)
            .share_mode(0)
            .open(&f.exe)
            .expect("lock the stub exe");

        spawn_helper(&f.script).expect("the helper must spawn");

        // Two-plus poll intervals (the sleep is `ping -n 2`, ~1 s).
        std::thread::sleep(std::time::Duration::from_millis(2500));
        assert!(
            f.script.exists(),
            "the helper must still be waiting while the exe is locked"
        );
        assert!(
            f.setup.exists(),
            "the installer must not have been touched while the exe is locked"
        );
        assert!(
            !std::fs::read_to_string(&f.log).is_ok_and(|l| l.contains("setup exited")),
            "Setup must NOT have been invoked while the exe is locked"
        );

        drop(lock);

        let finished = poll_until(SPAWN_DEADLINE, || !f.script.exists());
        assert!(
            finished,
            "the helper must complete once the exe lock is released, but it did \
             not within {SPAWN_DEADLINE:?}"
        );
        let log = std::fs::read_to_string(&f.log).expect("the helper must have written update.log");
        assert!(
            log.contains("setup exited"),
            "the wait released and the helper ran on; update.log said:\n{log}"
        );
        // Waited on for the same reason as in the test above, and for one more:
        // removing this directory before the relaunched stub has read its
        // `exit` would strand a `cmd /K` on the owner's desktop.
        assert!(
            poll_until(std::time::Duration::from_secs(10), || f.relaunched.exists()),
            "the relaunch must fire once the wait releases"
        );

        let _ = std::fs::remove_dir_all(&f.dir);
    }

    /// The full sequence with the spawn stubbed out: the marker is written
    /// FIRST and in its pessimistic form, and the script lands at the given
    /// path with exactly the golden text.
    ///
    /// The stub asserts the ordering from inside the sequence — by the time
    /// anything is spawned, the marker must already exist.
    #[test]
    fn begin_apply_writes_the_marker_before_the_script() {
        let dir = scratch_dir("sequence");
        let marker = dir.join("update-result.json");
        let log = dir.join("update.log");
        let script = dir.join("rc-update-test.cmd");
        let setup = dir.join("RemoteControl-Setup-v1.6.0.exe");
        let exe = dir.join("RemoteControl.exe");

        let spawned = std::cell::Cell::new(false);
        let got = begin_apply_with(
            "1.6.0",
            &setup,
            &marker,
            &log,
            &script,
            &exe,
            |p: &Path| {
                assert!(
                    marker.exists(),
                    "the pessimistic marker must exist before anything is spawned"
                );
                assert_eq!(p, script);
                spawned.set(true);
                Ok(())
            },
        );

        assert!(got.is_ok());
        assert!(spawned.get(), "the helper must be handed off");

        // The marker is the pessimistic form, verbatim.
        let marker_text = std::fs::read_to_string(&marker).unwrap();
        assert!(marker_text.contains("\"target\":\"1.6.0\""));
        assert!(marker_text.contains("\"ok\":false"));
        assert!(marker_text.contains("\"error\":\"installer\""));

        // The script is the golden text for these exact paths.
        let script_text = std::fs::read_to_string(&script).unwrap();
        assert_eq!(
            script_text,
            helper_script(std::process::id(), &setup, &exe, &marker, &log, "1.6.0")
        );
        assert!(script_text.contains(&format!("set \"PID={}\"", std::process::id())));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A script that cannot be written is `installer` — and the pessimistic
    /// marker still survives, which is the whole point of writing it first.
    #[test]
    fn a_failed_script_write_is_installer_and_leaves_the_marker() {
        let dir = scratch_dir("nowrite");
        let marker = dir.join("update-result.json");
        // A path under a directory that does not exist.
        let script = dir.join("absent").join("rc-update-test.cmd");

        let got = begin_apply_with(
            "1.6.0",
            &dir.join("setup.exe"),
            &marker,
            &dir.join("update.log"),
            &script,
            &dir.join("RemoteControl.exe"),
            |_: &Path| panic!("the spawn must not be reached when the write failed"),
        );

        assert_eq!(got.unwrap_err(), UpdateError::Installer);
        assert!(
            marker.exists(),
            "an interrupted sequence must still leave an honest record (D-16)"
        );
        assert!(!script.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A failed spawn is `installer` too, the marker stays pessimistic, and
    /// the orphaned script is cleaned up rather than left in `%TEMP%`.
    #[test]
    fn a_failed_spawn_is_installer_and_cleans_up_the_script() {
        let dir = scratch_dir("nospawn");
        let marker = dir.join("update-result.json");
        let script = dir.join("rc-update-test.cmd");

        let got = begin_apply_with(
            "1.6.0",
            &dir.join("setup.exe"),
            &marker,
            &dir.join("update.log"),
            &script,
            &dir.join("RemoteControl.exe"),
            |_: &Path| {
                Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "C:\\a\\path\\that\\must\\not\\travel",
                ))
            },
        );

        assert_eq!(
            got.unwrap_err(),
            UpdateError::Installer,
            "every failure path collapses to the closed-vocabulary code"
        );
        assert_eq!(got.unwrap_err().code(), "installer");
        assert!(marker.exists());
        assert!(!script.exists(), "an unspawned helper must not be left behind");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The relaunch target is `{app}\RemoteControl.exe`, rebuilt from the
    /// running exe's directory — the same directory, and the same fixed name
    /// the installer's `DestName` produces.
    #[test]
    fn installed_exe_is_the_installer_name_in_the_current_directory() {
        let got = installed_exe();
        assert_eq!(got.file_name().unwrap(), INSTALLED_EXE_NAME);
        assert_eq!(
            got.parent().unwrap(),
            std::env::current_exe().unwrap().parent().unwrap()
        );
    }

    /// The installer defines this name; a rename on one side only breaks the
    /// relaunch silently (the `mutex_name_matches_the_installer_contract`
    /// template).
    #[test]
    fn installed_exe_name_matches_the_installer_contract() {
        assert_eq!(INSTALLED_EXE_NAME, "RemoteControl.exe");
    }

    /// The helper's own path is per-PID and under `%TEMP%`.
    #[test]
    fn helper_script_path_is_per_pid_under_temp() {
        let p = helper_script_path();
        assert_eq!(p.parent().unwrap(), std::env::temp_dir());
        assert_eq!(
            p.file_name().unwrap().to_str().unwrap(),
            format!("rc-update-{}.cmd", std::process::id())
        );
    }

    /// The sweep's reason to exist: a wedged attempt's leaked script and its
    /// ~5.9 MB setup exe are both removed.
    #[test]
    fn the_sweep_removes_a_foreign_script_and_a_stale_setup() {
        let dir = scratch_dir("sweep-removes");
        let script = dir.join("rc-update-999999.cmd");
        let setup = dir.join("RemoteControl-Setup-v1.2.3.exe");
        std::fs::write(&script, b"leftover").unwrap();
        std::fs::write(&setup, b"leftover").unwrap();

        let own = dir.join(helper_script_path().file_name().unwrap());
        assert_eq!(sweep_temp_orphans_in(&dir, &own, Duration::ZERO), 2);
        assert!(!script.exists(), "a foreign-PID helper script is an orphan");
        assert!(!setup.exists(), "a leaked setup exe is an orphan");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The load-bearing safety assertion: this process's own script survives
    /// even with the age guard disabled. A sweep that can delete the script it
    /// is about to spawn would break the update it is cleaning up after.
    #[test]
    fn the_sweep_never_removes_this_process_own_script() {
        let dir = scratch_dir("sweep-own");
        let own = dir.join(helper_script_path().file_name().unwrap());
        std::fs::write(&own, b"mine").unwrap();

        assert_eq!(sweep_temp_orphans_in(&dir, &own, Duration::ZERO), 0);
        assert!(
            own.exists(),
            "the sweep must never remove the current process's own script"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `%TEMP%` belongs to everyone. Nothing outside the two anchored patterns
    /// is touched — and a DIRECTORY named like a candidate is not either.
    #[test]
    fn the_sweep_leaves_every_neighbour_alone() {
        let dir = scratch_dir("sweep-neighbours");
        let neighbours = [
            "notes.txt",
            "cleanup.cmd",
            "RemoteControl-Setup-v1.2.3.exe.part",
        ];
        for n in neighbours {
            std::fs::write(dir.join(n), b"not ours").unwrap();
        }
        let dir_like_a_candidate = dir.join("rc-update-123456.cmd");
        std::fs::create_dir(&dir_like_a_candidate).unwrap();

        let own = dir.join(helper_script_path().file_name().unwrap());
        assert_eq!(sweep_temp_orphans_in(&dir, &own, Duration::ZERO), 0);
        for n in neighbours {
            assert!(dir.join(n).exists(), "{n} is not ours to delete");
        }
        assert!(
            dir_like_a_candidate.is_dir(),
            "a directory is never a candidate, whatever it is called"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The age guard: a helper from a previous process could still be counting
    /// down its bounded wait, so nothing recent is removed.
    #[test]
    fn the_sweep_leaves_a_fresh_orphan_alone() {
        let dir = scratch_dir("sweep-fresh");
        let fresh = dir.join("rc-update-999999.cmd");
        std::fs::write(&fresh, b"just written").unwrap();

        let own = dir.join(helper_script_path().file_name().unwrap());
        assert_eq!(sweep_temp_orphans_in(&dir, &own, MIN_ORPHAN_AGE), 0);
        assert!(fresh.exists(), "a fresh file may still be in use");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An unsweepable directory is not an error and above all not a panic —
    /// the `truncate_update_log_if_large` posture.
    #[test]
    fn the_sweep_on_a_missing_directory_is_zero() {
        let missing = std::env::temp_dir().join("rc-apply-test-definitely-absent-dir");
        let _ = std::fs::remove_dir_all(&missing);

        assert_eq!(
            sweep_temp_orphans_in(&missing, &helper_script_path(), Duration::ZERO),
            0
        );
    }

    /// The anti-drift pin: the sweep is checked against the names its WRITERS
    /// actually produce, not against hand-typed ones. This is the test that
    /// fails if someone renames a constant on one side only.
    #[test]
    fn the_sweep_matches_the_names_its_writers_actually_produce() {
        let dir = scratch_dir("sweep-drift");

        let setup = dir.join(download::temp_path_for("1.2.3").file_name().unwrap());
        let script = dir.join(helper_script_path().file_name().unwrap());
        std::fs::write(&setup, b"written by temp_path_for's name").unwrap();
        std::fs::write(&script, b"written by helper_script_path's name").unwrap();

        // A DIFFERENT process's script name, so the real one is not skipped by
        // the PID guard — the matcher itself is what is under test here.
        let own = dir.join("rc-update-0.cmd");
        assert_eq!(
            sweep_temp_orphans_in(&dir, &own, Duration::ZERO),
            2,
            "the sweep must match download::temp_path_for and helper_script_path \
             by construction — if this fails, a constant drifted on one side"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The creation flags are the documented MS values, asserted rather than
    /// trusted to a comment — and, the assertion that would have caught the
    /// shipped defect, `DETACHED_PROCESS` is NOT among the flags we pass.
    #[test]
    fn creation_flags_are_the_documented_values() {
        assert_eq!(DETACHED_PROCESS, 8);
        assert_eq!(CREATE_NO_WINDOW, 134_217_728);

        assert_eq!(
            HELPER_CREATION_FLAGS, CREATE_NO_WINDOW,
            "the helper is spawned with CREATE_NO_WINDOW alone"
        );
        assert_eq!(
            HELPER_CREATION_FLAGS & DETACHED_PROCESS,
            0,
            "DETACHED_PROCESS | CREATE_NO_WINDOW is NOT a valid pair — MS makes \
             CREATE_NO_WINDOW ignored when DETACHED_PROCESS is set, leaving the \
             child with no console at all. Shipping that pair IS the 1.6.0/1.6.1 \
             self-update defect; never re-add it."
        );
    }
}
