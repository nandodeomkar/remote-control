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

use super::UpdateError;
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

/// `%TEMP%\rc-update-<pid>.cmd` — the helper's own path.
///
/// Per-PID so two attempts (or a stale file from a previous run) can never
/// share one script, and under `%TEMP%` because that is where a self-deleting
/// throwaway belongs. T-12-30 accepts the residual: a local process able to
/// rewrite `%TEMP%` between the write and the spawn already owns the machine.
pub fn helper_script_path() -> PathBuf {
    std::env::temp_dir().join(format!("rc-update-{}.cmd", std::process::id()))
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
    fn scratch_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rc-apply-test-{}-{tag}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create scratch dir");
        dir
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
