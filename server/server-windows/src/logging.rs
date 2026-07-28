//! Subscriber assembly (quick 260729-4rg): a rolling daily file under
//! `%APPDATA%/RemoteControl/logs`, plus stdout in development builds.
//!
//! WHY A FILE SINK EXISTS AT ALL: the release binary is
//! `windows_subsystem = "windows"` (see `main.rs`), so it has no console and
//! `stdout` goes nowhere. Before that change stdout was the ONLY sink, which
//! was survivable only because a console was always on screen. Hiding the
//! console without this module would have traded a cosmetic annoyance for
//! zero diagnostics.
//!
//! SECURITY (threats T-02-ID / T-03-04): what may be logged is unchanged by
//! moving the sink — lifecycle events and counts only, never frame contents,
//! move deltas, PINs, or tokens. A file sink makes that rule matter MORE than
//! it did with an ephemeral console: these records persist on disk until the
//! owner deletes them. The pairing PIN in particular still reaches only the
//! pair window, a toast, and (in dev builds) stdout — never a tracing sink.
//!
//! DEGRADE, NEVER CRASH: an unwritable log directory yields a subscriber with
//! no file layer rather than an error return. The same discipline as
//! `config::load` and `main.rs`'s `machine_guid` — diagnostics are support
//! machinery, and support machinery must never be the reason the owner cannot
//! start their own server.

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, fmt};

/// Stdout layer for development builds only — release has no console.
///
/// A function rather than a local binding because the two subscriber shapes
/// below (with and without a file layer) are different types, and one
/// inferred `Option<Layer<S>>` cannot serve both `S`s. `Option<Layer>`
/// implements `Layer`, so `None` is a no-op layer and neither arm needs a
/// `#[cfg]` duplicate of the whole builder.
fn stdout_layer<S>() -> Option<fmt::Layer<S>>
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    cfg!(debug_assertions).then(fmt::layer)
}

/// Install the global subscriber.
///
/// Returns the [`WorkerGuard`] for the non-blocking file writer, or `None`
/// when no file layer could be installed (unwritable log directory).
///
/// THE RETURN VALUE MUST BE HELD FOR THE PROCESS LIFETIME. `non_blocking`
/// hands writes to a background thread; dropping the guard flushes and stops
/// it, so binding this to `_` instead of a named local would drop it
/// immediately and silently truncate the log to nothing. Binding it at `main`
/// scope keeps the tail — the records that matter when diagnosing why the
/// process died.
#[must_use = "dropping the guard stops the log writer; bind it for the whole of main"]
pub fn init() -> Option<WorkerGuard> {
    // Unchanged from the pre-file-sink behaviour: RUST_LOG if set, else info.
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));

    let dir = crate::config::log_dir();
    match std::fs::create_dir_all(&dir) {
        Ok(()) => {
            // Daily rotation: `server.log.YYYY-MM-DD`. Old files are left in
            // place — the uninstaller's "delete settings" prompt is what
            // clears them, so a reinstall-to-fix cycle keeps the evidence of
            // what went wrong.
            let appender = tracing_appender::rolling::daily(&dir, "server.log");
            let (writer, guard) = tracing_appender::non_blocking(appender);

            tracing_subscriber::registry()
                .with(filter)
                // ANSI off: colour escapes are noise in a file the owner may
                // open in Notepad.
                .with(fmt::layer().with_ansi(false).with_writer(writer))
                .with(stdout_layer())
                .init();

            tracing::info!(dir = %dir.display(), "logging to file");
            Some(guard)
        }
        Err(e) => {
            tracing_subscriber::registry()
                .with(filter)
                .with(stdout_layer())
                .init();

            // Logged through the very subscriber just installed: in a release
            // build with no file layer this reaches nobody, which is the
            // honest outcome — there is nowhere left to report it. It still
            // shows up under `cargo run`, where this is actually debuggable.
            tracing::warn!(
                dir = %dir.display(),
                error = %e,
                "could not create the log directory; continuing without a log file"
            );
            None
        }
    }
}
