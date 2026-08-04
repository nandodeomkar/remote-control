//! On-demand egui-on-winit settings window (SRV-03/SRV-02/SRV-04) hosted on
//! the shell thread's SHARED winit loop — egui + egui-winit + egui_glow
//! driven directly, deliberately NOT egui's `run_native` framework wrapper
//! (that wrapper owns its own event loop and cannot share the tray's —
//! RESEARCH Pitfall 4 / egui#2875).
//!
//! Lifecycle: created ON DEMAND when [`super::UserEvent::OpenSettings`]
//! fires (the tray's Settings item), destroyed when the owner closes the
//! window. The tray — and the whole server — outlives every open/close
//! cycle. The GL context/surface plumbing mirrors egui_glow 0.35's own
//! `pure_glow` example (glutin 0.32 + glutin-winit 0.5, the exact pairing
//! egui_glow tests against).
//!
//! What it manages (SRV-03):
//! - device name / port / clipboard-sync — persisted through the 07-07
//!   config path via the [`super::ShellCtx::config`] shared handle; a port
//!   or name change shows "Restart to apply" (RESEARCH Open Q3 — the
//!   listener and beacon bind once at startup, no live re-bind).
//! - autostart — [`crate::autostart`] HKCU Run toggle (SRV-02), applied
//!   immediately.
//! - repaint scheduling rides the shell loop's `UserEvent` queue (egui's
//!   request-repaint callback → `SettingsRepaint`), so delayed repaints
//!   (cursor blink) never busy-spin the loop.

use std::sync::atomic::Ordering;
use std::time::Duration;

use server_core::executors::UpdateProgress;
use winit::dpi::LogicalSize;
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

use super::chrome::{self, ShellAction};
use super::glwin::GlWindow;
use super::style::{self, icon};
use super::{ShellCtx, UserEvent};
use crate::firewall::FirewallStatus;
use crate::{autostart, config};
use crate::update::UpdateError;
use crate::update::update_thread::{
    STAGE_CHECKING, STAGE_DOWNLOADING, STAGE_FAILED, STAGE_INSTALLING, STAGE_RESTARTING,
    STAGE_UPTODATE, STAGE_VERIFYING, UpdateCmd,
};

// ─────────────────────────────────────────────────────────────────────────
// UPDATES section copy (12-UI-SPEC § PC Settings Window — quoted, not
// re-worded)
// ─────────────────────────────────────────────────────────────────────────
//
// Named consts rather than inline literals — a divergence from this file's
// own style, and a deliberate one. These sentences are a CONTRACT SHARED WITH
// THE PHONE (`app/remote_control/lib/update/updates_screen.dart`): two
// surfaces describing one failure with different words is the single most
// confusing outcome available to this phase. Naming them makes the shared
// vocabulary greppable and lets one unit test assert the whole map.

/// The running version — from the package itself (D-05, SC2), never a
/// hardcoded constant. A stale literal here is the exact bug this phase
/// exists to end.
const RUNNING_VERSION: &str = env!("CARGO_PKG_VERSION");

/// No check has happened this run.
const UPDATE_NEVER_CHECKED: &str = "Not checked yet.";

/// `checking`. The ellipsis is the single character U+2026.
const UPDATE_CHECKING: &str = "Checking…";

/// `uptodate` with no newer version — `Up to date · {version}`.
const UPDATE_UP_TO_DATE_PREFIX: &str = "Up to date · ";

/// The version transition arrow, U+2192, with its surrounding spaces.
const UPDATE_TRANSITION_ARROW: &str = " → ";

/// `downloading` — `Downloading… {pct}%`.
const UPDATE_DOWNLOADING_PREFIX: &str = "Downloading… ";

/// `downloading` suffix.
const UPDATE_DOWNLOADING_SUFFIX: &str = "%";

/// `verifying` — no jargon: never "sha256", never "checksum".
const UPDATE_VERIFYING: &str = "Checking the download…";

/// `installing`.
const UPDATE_INSTALLING: &str = "Installing…";

/// `restarting`. NOT the phone's `Restarting on your PC…` — see the note on
/// [`update_status`].
const UPDATE_RESTARTING: &str = "Restarting…";

/// D-11 `network`.
const UPDATE_FAIL_NETWORK: &str = "Download failed — check your connection.";

/// D-11 `checksum`. "Signature", never "sha256".
const UPDATE_FAIL_CHECKSUM: &str =
    "The download didn't match its signature. Nothing was installed.";

/// D-11 `disk`.
const UPDATE_FAIL_DISK: &str = "Not enough space for the download.";

/// D-11 `installer` — `The installer didn't finish. Your PC is still on
/// {installed}.`
const UPDATE_FAIL_INSTALLER_PREFIX: &str = "The installer didn't finish. Your PC is still on ";

/// The full stop after `{installed}`.
const UPDATE_FAIL_INSTALLER_SUFFIX: &str = ".";

/// D-11 `stale`.
const UPDATE_FAIL_STALE: &str = "That version is no longer the latest. Check again.";

/// The action while nothing newer is known.
const UPDATE_BUTTON_CHECK: &str = "Check for updates";

/// The action once the SERVER has resolved something newer.
const UPDATE_BUTTON_APPLY: &str = "Update now";

/// How often the section asks for a repaint while a stage is live — the
/// update thread's own publication cadence, so the status line follows a
/// download without the window spinning between ticks.
const UPDATE_TICK: Duration = Duration::from_millis(250);

/// Which of the three status-line colour roles a line takes (12-UI-SPEC § PC
/// Settings Window rule table).
///
/// A role rather than a `Color32` so [`update_status`] stays pure and its test
/// asserts the CONTRACT ("this state is the failure colour") instead of a hex
/// value that would then be asserted twice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tone {
    /// Idle or up to date.
    Muted,
    /// An update is available or in progress — the same treatment the shipped
    /// `Restart to apply` hint uses.
    Accent,
    /// A failure — the same treatment the shipped `Not a valid port` line
    /// uses.
    Red,
}

impl Tone {
    fn color(self) -> egui::Color32 {
        match self {
            Tone::Muted => style::MUTED,
            Tone::Accent => style::ACCENT,
            Tone::Red => style::RED,
        }
    }
}

/// One rendered status line: the sentence and its colour role.
#[derive(Debug, Clone, PartialEq, Eq)]
struct UpdateStatus {
    text: String,
    tone: Tone,
}

impl UpdateStatus {
    fn new(text: impl Into<String>, tone: Tone) -> Self {
        Self {
            text: text.into(),
            tone,
        }
    }
}

/// The wire code → [`UpdateError`] lookup, over the ONE closed vocabulary.
///
/// Resolved through [`UpdateError::ALL`] rather than by matching string
/// literals here, so this file cannot drift from SPEC §7: a code added there
/// arrives here automatically, and a code spelled wrong here matches nothing
/// and degrades rather than silently rendering the wrong sentence.
fn failure_of(code: &str) -> Option<UpdateError> {
    UpdateError::ALL.into_iter().find(|e| e.code() == code)
}

/// The stage → sentence map: the whole user-visible vocabulary of this
/// section, as one pure function (the crate's pure-function factoring rule).
///
/// `None` means **render nothing new** — the one swallowed code. `busy` says
/// "your click arrived while an apply was already running", which the line is
/// already showing; surfacing it would blame the local user for a race the
/// disabled button does not even let them provoke (D-11 rule 7). The phone
/// swallows it the same way.
///
/// Two departures from the phone's sentence for the same state, both because
/// the phone's wording is written from the phone's vantage point:
///
///   * `restarting` renders `Restarting…`, not `Restarting on your PC…`. The
///     UI-SPEC's PC copy list deliberately does not carry that sentence over,
///     and "your PC" reads wrong on the window that IS the PC. It is not a
///     failure sentence, so the D-11 shared-failure-vocabulary rule is
///     untouched.
///   * the available line is `{installed} → {latest}` with no size clause.
///     [`UpdateProgress`] carries no asset size — it is not on the wire — and
///     the plan forbids a second feed fetch to obtain one. A missing size is a
///     smaller loss than an invented one.
///
/// Everything else is quoted from the shared copy table verbatim, including
/// the `installer` sentence's "Your PC", which IS about this machine's
/// installed version and is a failure sentence besides.
fn update_status(progress: &UpdateProgress, running: &str) -> Option<UpdateStatus> {
    match progress.stage.as_str() {
        // The never-sent initial watch value: nothing has happened yet.
        "" => Some(UpdateStatus::new(UPDATE_NEVER_CHECKED, Tone::Muted)),
        STAGE_CHECKING => Some(UpdateStatus::new(UPDATE_CHECKING, Tone::Accent)),
        STAGE_DOWNLOADING => Some(UpdateStatus::new(
            format!(
                "{UPDATE_DOWNLOADING_PREFIX}{}{UPDATE_DOWNLOADING_SUFFIX}",
                progress.pct.unwrap_or(0)
            ),
            Tone::Accent,
        )),
        STAGE_VERIFYING => Some(UpdateStatus::new(UPDATE_VERIFYING, Tone::Accent)),
        STAGE_INSTALLING => Some(UpdateStatus::new(UPDATE_INSTALLING, Tone::Accent)),
        STAGE_RESTARTING => Some(UpdateStatus::new(UPDATE_RESTARTING, Tone::Accent)),
        // The check's terminal in BOTH outcomes; `version` carries the
        // distinction (see `update_thread::run_check`).
        STAGE_UPTODATE => Some(match progress.version.as_deref() {
            Some(latest) => UpdateStatus::new(
                format!("{running}{UPDATE_TRANSITION_ARROW}{latest}"),
                Tone::Accent,
            ),
            None => UpdateStatus::new(
                format!("{UPDATE_UP_TO_DATE_PREFIX}{running}"),
                Tone::Muted,
            ),
        }),
        STAGE_FAILED => match failure_of(progress.error.as_deref().unwrap_or_default()) {
            Some(UpdateError::Busy) => None,
            Some(UpdateError::Network) => {
                Some(UpdateStatus::new(UPDATE_FAIL_NETWORK, Tone::Red))
            }
            Some(UpdateError::Checksum) => {
                Some(UpdateStatus::new(UPDATE_FAIL_CHECKSUM, Tone::Red))
            }
            Some(UpdateError::Disk) => Some(UpdateStatus::new(UPDATE_FAIL_DISK, Tone::Red)),
            Some(UpdateError::Stale) => Some(UpdateStatus::new(UPDATE_FAIL_STALE, Tone::Red)),
            // `downgrade` is impossible through this surface — the button can
            // only send a version the server itself resolved as strictly newer
            // — so if it arrives, something is wrong that the local user did
            // not do. Render the generic sentence and log the real code, which
            // is what the phone does with it too.
            Some(UpdateError::Downgrade) => {
                tracing::warn!(
                    "update: settings window received a downgrade refusal it cannot have caused"
                );
                Some(UpdateStatus::new(
                    format!(
                        "{UPDATE_FAIL_INSTALLER_PREFIX}{running}{UPDATE_FAIL_INSTALLER_SUFFIX}"
                    ),
                    Tone::Red,
                ))
            }
            // `installer`, and every unrecognised code from a future server.
            // An honest generic beats a specific guess.
            _ => Some(UpdateStatus::new(
                format!("{UPDATE_FAIL_INSTALLER_PREFIX}{running}{UPDATE_FAIL_INSTALLER_SUFFIX}"),
                Tone::Red,
            )),
        },
        // A stage from a future server: leave the line alone rather than
        // blanking it.
        _ => None,
    }
}

/// The on-demand settings window: a [`GlWindow`] (winit + glutin + egui)
/// plus the immediate-mode edit state.
pub struct SettingsWindow {
    gl: GlWindow,
    ui: UiState,
}

impl SettingsWindow {
    /// Build the window ON the shell loop (must be called from the shell
    /// thread with its `ActiveEventLoop`). Every fallible step surfaces as
    /// `anyhow::Error` so the caller can log-and-continue — a failed
    /// settings window must never kill the tray.
    pub fn new(
        event_loop: &ActiveEventLoop,
        ctx: &ShellCtx,
        proxy: EventLoopProxy<UserEvent>,
    ) -> anyhow::Result<Self> {
        let attrs = Window::default_attributes()
            .with_title("Remote Control — Settings")
            .with_inner_size(LogicalSize::new(440.0, 560.0))
            .with_resizable(false)
            .with_decorations(false);
        let gl = GlWindow::new(event_loop, attrs, proxy)?;
        chrome::round_corners(gl.window());
        gl.show();
        gl.request_redraw();

        // Seed the edit buffers from the live shared settings (07-07 values
        // as edited so far this run) + the real registry autostart state.
        let shared = ctx
            .config
            .lock()
            .expect("settings mutex poisoned at window open")
            .clone();
        let ui = UiState {
            device_name: shared.device_name.unwrap_or_default(),
            port_text: shared.port.map(|p| p.to_string()).unwrap_or_default(),
            autostart_enabled: autostart::is_enabled(),
            restart_needed: false,
            autostart_error: false,
            update_latest: None,
            update_status: UpdateStatus::new(UPDATE_NEVER_CHECKED, Tone::Muted),
        };
        Ok(Self { gl, ui })
    }

    /// The winit id — the shell loop routes `WindowEvent`s by it.
    pub fn window_id(&self) -> WindowId {
        self.gl.window_id()
    }

    /// Bring an already-open window to the front (second Settings click).
    pub fn focus(&self) {
        self.gl.focus();
    }

    /// Ask the OS for a redraw (egui repaint scheduling).
    pub fn request_redraw(&self) {
        self.gl.request_redraw();
    }

    /// Resize the GL surface with the window.
    pub fn resize(&self, size: winit::dpi::PhysicalSize<u32>) {
        self.gl.resize(size);
    }

    /// Forward a window event to egui; returns whether egui wants a repaint.
    pub fn on_window_event(&mut self, event: &winit::event::WindowEvent) -> bool {
        self.gl.on_window_event(event)
    }

    /// Run one egui frame + paint + swap (the `RedrawRequested` handler).
    pub fn redraw(&mut self, ctx: &ShellCtx) -> Vec<ShellAction> {
        let mut actions = Vec::new();
        let ui_state = &mut self.ui;
        self.gl.redraw(style::BG_CLEAR, |window, ui| {
            if let Some(a) = chrome::title_bar(ui, window, "Remote Control — Settings", false) {
                actions.push(a);
            }
            ui_state.render(ctx, ui);
        });
        actions
    }

    /// Commit any in-progress text edits (called on window close so a typed
    /// device name / port is never lost to a missing lost-focus event).
    pub fn commit_pending(&mut self, ctx: &ShellCtx) {
        self.ui.commit_device_name(ctx);
        self.ui.commit_port(ctx);
    }

    /// Release GPU resources (called right before the window is dropped).
    pub fn destroy(&mut self) {
        self.gl.destroy();
    }
}

/// Immediate-mode UI state: the text-edit buffers + inline note flags.
struct UiState {
    /// Device-name edit buffer (empty = use `COMPUTERNAME`).
    device_name: String,
    /// Port edit buffer (empty = use the default port).
    port_text: String,
    /// Cached HKCU Run state — refreshed only on toggle, never per frame.
    autostart_enabled: bool,
    /// A committed name/port change needs a restart (RESEARCH Open Q3 —
    /// the listener and beacon bind once at startup; no live re-bind).
    restart_needed: bool,
    /// The last autostart toggle failed (registry write error).
    autostart_error: bool,
    /// The newest version the SERVER resolved during its own check, and the
    /// ONLY value the `Update now` button may send back as an apply target
    /// (D-14). Populated from the progress watch's `uptodate` terminal — never
    /// from a second feed fetch, and never from anything a human typed: there
    /// is no text field here for one to arrive through.
    update_latest: Option<String>,
    /// The last status line the watch produced. Held rather than re-derived so
    /// the one swallowed code (`busy`) can leave the line exactly as it was.
    update_status: UpdateStatus,
}

impl UiState {
    /// One immediate-mode frame: fields bound to the shared settings handle,
    /// the autostart toggle, the paired-device list, and the firewall hint —
    /// restyled to the Phase 10 handoff (panel 1d).
    fn render(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        egui::Frame::new()
            .inner_margin(egui::Margin::symmetric(22, 20))
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false; 2])
                    .show(ui, |ui| {
                        self.render_firewall_hint(ctx, ui);
                        style::section_label(ui, "GENERAL");
                        ui.add_space(12.0);
                        self.render_general(ctx, ui);
                        ui.add_space(22.0);
                        style::section_label(ui, "PAIRED DEVICES");
                        ui.add_space(12.0);
                        self.render_paired_devices(ctx, ui);
                        ui.add_space(22.0);
                        style::section_label(ui, "UPDATES");
                        ui.add_space(12.0);
                        self.render_updates(ctx, ui);
                    });
            });
    }

    /// SRV-04 / D-06: the PERSISTENT firewall hint — rendered every frame
    /// the window is open, whenever the startup self-test could not confirm
    /// inbound is allowed. Read-only status; the text carries no secret
    /// (T-07-34).
    fn render_firewall_hint(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        if !ctx.notify_firewall {
            return;
        }
        let port = ctx.resolved_port;
        let (title, body, accent, fill, border) = match ctx.firewall_status {
            FirewallStatus::BlockedNoRule => (
                format!("Firewall is blocking TCP {port}"),
                "Your phone can't connect. Allow Remote Control through Windows Firewall."
                    .to_string(),
                style::RED,
                style::RED_TINT,
                style::RED_TINT_BORDER,
            ),
            _ => (
                format!("Couldn't confirm the firewall allows TCP {port}"),
                "If your phone can't connect, allow Remote Control through Windows Firewall."
                    .to_string(),
                style::AMBER,
                style::SURFACE,
                style::BORDER,
            ),
        };
        style::card(fill, border, 14, 14).show(ui, |ui| {
            ui.horizontal_top(|ui| {
                ui.spacing_mut().item_spacing.x = 12.0;
                style::status_dot(ui, accent, 14.0);
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 4.0;
                    ui.label(egui::RichText::new(title).font(style::sg_sb(14.0)).color(accent));
                    ui.label(
                        egui::RichText::new(body)
                            .font(style::sg(12.0))
                            .color(style::MUTED),
                    );
                });
            });
        });
        ui.add_space(16.0);
    }

    /// Device name / port / clipboard-sync / autostart (SRV-03 + SRV-02).
    fn render_general(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        // Device name.
        field_label(ui, "Device name", Some("(shown on your phone)"));
        ui.add_space(7.0);
        let name = ui.add(
            egui::TextEdit::singleline(&mut self.device_name)
                .hint_text("This computer's name")
                .font(style::sg(14.0))
                .margin(egui::Margin::symmetric(13, 12))
                .desired_width(f32::INFINITY),
        );
        if name.lost_focus() {
            self.commit_device_name(ctx);
        }
        ui.add_space(16.0);

        // Port + restart hint.
        field_label(ui, "Port", None);
        ui.add_space(7.0);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 12.0;
            let port = ui.add(
                egui::TextEdit::singleline(&mut self.port_text)
                    .hint_text(ctx.resolved_port.to_string())
                    .font(style::mono(14.0))
                    .margin(egui::Margin::symmetric(13, 12))
                    .desired_width(84.0),
            );
            if port.lost_focus() {
                self.commit_port(ctx);
            }
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 6.0;
                ui.label(style::icon_rt(icon::INFO, 15.0, style::ACCENT));
                ui.label(
                    egui::RichText::new("Restart to apply")
                        .font(style::sg(12.0))
                        .color(style::ACCENT),
                );
            });
        });
        if !self.port_text.trim().is_empty() && parse_port(self.port_text.trim()).is_none() {
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Not a valid port (1–65535)")
                    .font(style::sg(12.0))
                    .color(style::RED),
            );
        }
        ui.add_space(20.0);
        hairline(ui);
        ui.add_space(20.0);

        // Clipboard sync (RESEARCH Open Q5): the AtomicBool is the LIVE gate
        // the clip thread's auto-sync push reads — flipping it applies
        // immediately; the config write makes it stick across restarts.
        let mut clip = ctx.clip_sync.load(Ordering::Relaxed);
        if toggle_row(
            ui,
            "Clipboard sync",
            "Send this PC's clipboard to the phone",
            &mut clip,
        ) {
            ctx.clip_sync.store(clip, Ordering::Relaxed);
            ctx.config
                .lock()
                .expect("settings mutex poisoned (clipboard toggle)")
                .clipboard_sync = clip;
            persist(ctx);
        }
        ui.add_space(6.0);

        // Autostart (SRV-02): HKCU-only Run entry via crate::autostart.
        let mut auto = self.autostart_enabled;
        if toggle_row(
            ui,
            "Start with Windows",
            "Launch for this user at sign-in",
            &mut auto,
        ) {
            self.autostart_enabled = auto;
            let result = if self.autostart_enabled {
                autostart::enable()
            } else {
                autostart::disable()
            };
            match result {
                Ok(()) => {
                    self.autostart_error = false;
                    ctx.config
                        .lock()
                        .expect("settings mutex poisoned (autostart toggle)")
                        .autostart = self.autostart_enabled;
                    persist(ctx);
                }
                Err(e) => {
                    // Degrade-never-panic: reflect the registry truth and
                    // surface an inline warning; the toggle stays usable.
                    tracing::warn!(error = %e, "autostart toggle failed");
                    self.autostart_enabled = autostart::is_enabled();
                    self.autostart_error = true;
                }
            }
        }
        if self.autostart_error {
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Couldn't update the Windows startup entry.")
                    .font(style::sg(12.0))
                    .color(style::RED),
            );
        }
    }

    /// D-04/D-05/D-02: the paired-device list with per-row Revoke + the
    /// on-demand "Pair new device" action. Names render ONLY here — the
    /// local operator's screen; the tray tooltip stays count-only (T-07-33).
    fn render_paired_devices(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        // Clone the records so the auth lock is NOT held while rendering —
        // revoke_device below re-takes it.
        let records = ctx
            .auth
            .lock()
            .expect("auth mutex poisoned rendering the paired list")
            .paired_records()
            .to_vec();

        style::card(style::SURFACE, style::BORDER, 12, 0).show(ui, |ui| {
            ui.spacing_mut().item_spacing = egui::Vec2::ZERO;
            if records.is_empty() {
                ui.allocate_ui(egui::vec2(ui.available_width(), 50.0), |ui| {
                    ui.add_space(9.0);
                    ui.horizontal(|ui| {
                        ui.add_space(14.0);
                        ui.label(
                            egui::RichText::new("No phones paired yet.")
                                .font(style::sg(13.5))
                                .color(style::MUTED),
                        );
                    });
                });
            }
            for device in &records {
                device_row(
                    ui,
                    &device.name,
                    &paired_ago(device.paired_at),
                    true,
                    || {
                        // D-05 (T-07-31): crate::revoke_device drops the
                        // stored hash + advances the revocation epoch so the
                        // live session force-disconnects.
                        crate::revoke_device(&ctx.auth, &ctx.revoke_tx, &device.hash);
                    },
                );
                hairline_full(ui);
            }
            // "Pair new device" accent action row.
            let resp = pair_row(ui);
            if resp.clicked() {
                // D-02 on demand: a fresh 60s PIN window + toast.
                crate::begin_on_demand_pairing(&ctx.auth);
            }
        });
    }

    /// D-06: this machine's OWN update path — a version line, a status line
    /// and one action.
    ///
    /// It exists so a broken, unpaired or absent phone does not leave the PC
    /// with no way to update itself. It performs its own feed check through
    /// the SAME update thread the phone-driven path commands, rather than
    /// opening a browser: "open a browser and download a file" is exactly the
    /// hand-download procedure this phase exists to delete.
    ///
    /// **No phone row and no extension row.** This is a fallback for this
    /// machine, not a second control centre.
    fn render_updates(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        field_label(ui, "Version", None);
        ui.add_space(7.0);
        ui.label(
            egui::RichText::new(RUNNING_VERSION)
                .font(style::mono(14.0))
                .color(style::TEXT),
        );
        ui.add_space(16.0);

        // One `borrow()` per frame off the shared watch — the same value the
        // session's `update.progress` push arm sends to the phone, so the two
        // surfaces cannot disagree. Cheap and lock-free; no clone of the
        // channel, no second source of truth.
        let progress = ctx.update_progress.borrow().clone();
        if progress.stage == STAGE_UPTODATE {
            // The server's own answer to "what is latest", and the only value
            // the apply button can ever carry (D-14).
            self.update_latest = progress.version.clone();
        }
        if let Some(status) = update_status(&progress, RUNNING_VERSION) {
            self.update_status = status;
        }
        ui.label(
            egui::RichText::new(&self.update_status.text)
                .font(style::sg(12.0))
                .color(self.update_status.tone.color()),
        );
        ui.add_space(12.0);

        // A live stage will keep publishing; ask for the next frame so the
        // percentage actually moves. The window is otherwise event-driven and
        // would sit on a stale line for the whole download.
        if matches!(
            progress.stage.as_str(),
            STAGE_CHECKING | STAGE_DOWNLOADING | STAGE_VERIFYING | STAGE_INSTALLING
                | STAGE_RESTARTING
        ) {
            ui.ctx().request_repaint_after(UPDATE_TICK);
        }

        // Disabled while an apply is in flight (T-12-60): the executor's
        // compare-and-swap would refuse a second one as `busy`, and a refusal
        // this surface then has to explain is worse than a button that is
        // plainly unavailable.
        let busy = ctx.update_busy.load(Ordering::Relaxed);
        let target = self.update_latest.clone();
        let (label, tint) = match &target {
            Some(_) => (UPDATE_BUTTON_APPLY, style::ACCENT),
            None => (UPDATE_BUTTON_CHECK, style::TEXT),
        };
        let clicked = ui
            .add_enabled(
                !busy,
                egui::Button::new(
                    egui::RichText::new(label)
                        .font(style::sg(13.5))
                        .color(if busy { style::MUTED } else { tint }),
                ),
            )
            .clicked();
        if clicked {
            // The apply target is the version the SERVER resolved. There is no
            // text field, no path picker and no way for anyone at this window
            // to name a file, a URL or a version of their own (T-12-01) — and
            // the thread re-runs the whole refusal ladder on it regardless.
            let cmd = match target {
                Some(version) => UpdateCmd::Apply(version),
                None => UpdateCmd::Check,
            };
            // Send-and-forget: a dead update thread is a degraded server, not
            // a reason to take the settings window down with it.
            if ctx.update_cmd.send(cmd).is_err() {
                tracing::warn!("update: the update thread is gone; the settings action was dropped");
            }
        }
    }

    /// Commit the device-name buffer to the shared settings + config file
    /// (empty/whitespace = clear the override, back to `COMPUTERNAME`).
    fn commit_device_name(&mut self, ctx: &ShellCtx) {
        let trimmed = self.device_name.trim();
        let value = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        };
        let mut shared = ctx
            .config
            .lock()
            .expect("settings mutex poisoned (device name)");
        if shared.device_name != value {
            shared.device_name = value;
            drop(shared);
            // The beacon identity binds the name once at startup — same
            // restart-to-apply story as the port (Open Q3).
            self.restart_needed = true;
            persist(ctx);
        }
    }

    /// Commit the port buffer (empty = clear back to the default; an invalid
    /// value is NEVER written — the inline error already shows).
    fn commit_port(&mut self, ctx: &ShellCtx) {
        let trimmed = self.port_text.trim();
        let value = if trimmed.is_empty() {
            None
        } else {
            match parse_port(trimmed) {
                Some(p) => Some(p),
                None => return,
            }
        };
        let mut shared = ctx.config.lock().expect("settings mutex poisoned (port)");
        if shared.port != value {
            shared.port = value;
            drop(shared);
            // Open Q3: restart-required — no live re-bind.
            self.restart_needed = true;
            persist(ctx);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Panel 1d row/field painting helpers (Phase 10 redesign)
// ─────────────────────────────────────────────────────────────────────────

/// A field caption: `Label (optional muted suffix)`.
fn field_label(ui: &mut egui::Ui, label: &str, sub: Option<&str>) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 5.0;
        ui.label(
            egui::RichText::new(label)
                .font(style::sg(12.5))
                .color(style::MUTED),
        );
        if let Some(s) = sub {
            ui.label(
                egui::RichText::new(s)
                    .font(style::sg(12.5))
                    .color(style::MUTED_2),
            );
        }
    });
}

/// A 1px divider spanning the current available width.
fn hairline(ui: &mut egui::Ui) {
    style::hairline(ui, style::BORDER_SOFT);
}

/// A divider spanning the full width of the enclosing card (list rows).
fn hairline_full(ui: &mut egui::Ui) {
    hairline(ui);
}

/// A title + subtitle row with a right-aligned [`style::toggle`]. Returns
/// whether the toggle changed this frame.
fn toggle_row(ui: &mut egui::Ui, title: &str, sub: &str, on: &mut bool) -> bool {
    let mut changed = false;
    ui.allocate_ui(egui::vec2(ui.available_width(), 44.0), |ui| {
        ui.horizontal_centered(|ui| {
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 2.0;
                ui.label(
                    egui::RichText::new(title)
                        .font(style::sg_sb(14.5))
                        .color(style::TEXT),
                );
                ui.label(
                    egui::RichText::new(sub)
                        .font(style::sg(12.0))
                        .color(style::MUTED_2),
                );
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                changed = style::toggle(ui, on).changed();
            });
        });
    });
    changed
}

use super::style::{device_row, pair_row};

/// Strict settings-side port parse: an integer in `1..=65535` (port 0 is not
/// a usable listen port — same rule as config.rs's lenient loader).
fn parse_port(text: &str) -> Option<u16> {
    text.parse::<u16>().ok().filter(|p| *p != 0)
}

/// Human "paired N days ago" for the device list (D-04).
fn paired_ago(paired_at: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    match now.saturating_sub(paired_at) / 86_400 {
        0 => "paired today".to_owned(),
        1 => "paired yesterday".to_owned(),
        n => format!("paired {n} days ago"),
    }
}

/// Serialize the CURRENT shared settings + live auth records to config.toml
/// — the settings window's write path through the 07-07 config module. The
/// paired records come from the auth store (single source of truth), so a
/// settings save can never drop a pairing that landed mid-edit.
fn persist(ctx: &ShellCtx) {
    let s = ctx
        .config
        .lock()
        .expect("settings mutex poisoned during save")
        .clone();
    let records = ctx
        .auth
        .lock()
        .expect("auth mutex poisoned during settings save")
        .paired_records()
        .to_vec();
    let cfg = config::from_auth(&records, s.device_name, s.port, s.autostart, s.clipboard_sync);
    config::save(&cfg);
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::{paired_ago, parse_port};

    /// A published value for `stage`, with no pct, version or error.
    fn at(stage: &str) -> UpdateProgress {
        UpdateProgress {
            stage: stage.to_string(),
            pct: None,
            version: None,
            error: None,
        }
    }

    /// A `failed` terminal carrying `code`.
    fn failed_with(code: &str) -> UpdateProgress {
        UpdateProgress {
            stage: STAGE_FAILED.to_string(),
            pct: None,
            version: None,
            error: Some(code.to_string()),
        }
    }

    /// Every stage in the D-10 vocabulary maps to its contract sentence and
    /// its contract colour role.
    #[test]
    fn update_status_maps_every_stage() {
        let running = "1.4.0";

        // The never-sent initial watch value.
        assert_eq!(
            update_status(&at(""), running),
            Some(UpdateStatus::new("Not checked yet.", Tone::Muted)),
            "the empty sentinel is never-checked, not a blank line"
        );

        assert_eq!(
            update_status(&at(STAGE_CHECKING), running),
            Some(UpdateStatus::new("Checking…", Tone::Accent))
        );

        let mut downloading = at(STAGE_DOWNLOADING);
        downloading.pct = Some(43);
        assert_eq!(
            update_status(&downloading, running),
            Some(UpdateStatus::new("Downloading… 43%", Tone::Accent))
        );
        // A pct-less downloading (defensive — the thread always sets one)
        // renders 0 rather than the word "None".
        assert_eq!(
            update_status(&at(STAGE_DOWNLOADING), running),
            Some(UpdateStatus::new("Downloading… 0%", Tone::Accent))
        );

        assert_eq!(
            update_status(&at(STAGE_VERIFYING), running),
            Some(UpdateStatus::new("Checking the download…", Tone::Accent)),
            "no jargon: never 'sha256', never 'checksum'"
        );
        assert_eq!(
            update_status(&at(STAGE_INSTALLING), running),
            Some(UpdateStatus::new("Installing…", Tone::Accent))
        );
        assert_eq!(
            update_status(&at(STAGE_RESTARTING), running),
            Some(UpdateStatus::new("Restarting…", Tone::Accent)),
            "NOT the phone's 'on your PC' wording — this window IS the PC"
        );

        // The check terminal, both outcomes. `version` carries the
        // distinction; the stage is `uptodate` either way.
        assert_eq!(
            update_status(&at(STAGE_UPTODATE), running),
            Some(UpdateStatus::new("Up to date · 1.4.0", Tone::Muted))
        );
        let mut available = at(STAGE_UPTODATE);
        available.version = Some("1.5.0".to_string());
        assert_eq!(
            update_status(&available, running),
            Some(UpdateStatus::new("1.4.0 → 1.5.0", Tone::Accent)),
            "an available update is the accent role, like 'Restart to apply'"
        );

        // A stage from a future server leaves the line alone.
        assert_eq!(update_status(&at("teleporting"), running), None);
    }

    /// All seven D-11 codes: five sentences, one degradation, one swallow.
    #[test]
    fn update_status_maps_every_error_code() {
        let running = "1.4.0";
        let installer_sentence = "The installer didn't finish. Your PC is still on 1.4.0.";

        for (code, expected) in [
            ("network", "Download failed — check your connection."),
            (
                "checksum",
                "The download didn't match its signature. Nothing was installed.",
            ),
            ("disk", "Not enough space for the download."),
            ("installer", installer_sentence),
            ("stale", "That version is no longer the latest. Check again."),
            // Impossible through this surface — degrades to the generic
            // sentence rather than blaming the local user.
            ("downgrade", installer_sentence),
        ] {
            assert_eq!(
                update_status(&failed_with(code), running),
                Some(UpdateStatus::new(expected, Tone::Red)),
                "{code} must render its contract sentence in the failure role"
            );
        }

        // The one swallowed code (D-11 rule 7): render nothing new.
        assert_eq!(
            update_status(&failed_with("busy"), running),
            None,
            "busy says an apply was already running — the line already shows it"
        );

        // Every one of the seven is accounted for above.
        assert_eq!(UpdateError::ALL.len(), 7);
        for e in UpdateError::ALL {
            assert!(
                failure_of(e.code()).is_some(),
                "{} is not resolvable from its own wire code",
                e.code()
            );
        }

        // An unrecognised code from a future server degrades to the generic
        // installer sentence — never to a blank line and never to a guess.
        assert_eq!(
            update_status(&failed_with("teleport-fault"), running),
            Some(UpdateStatus::new(installer_sentence, Tone::Red))
        );
        // …and a `failed` with no code at all does the same.
        assert_eq!(
            update_status(&at(STAGE_FAILED), running),
            Some(UpdateStatus::new(installer_sentence, Tone::Red))
        );
    }

    /// T-12-06: no path, URL, HTTP status, hash or exception text is
    /// REPRESENTABLE here — the mapping accepts only a stage and a code.
    #[test]
    fn update_status_cannot_render_a_detail() {
        let running = "1.4.0";
        // A hostile "code" is not in the vocabulary, so it degrades; the
        // string itself never reaches the sentence.
        for hostile in [
            "https://evil/x.exe",
            "C:\\Users\\me\\AppData\\Local\\Temp\\x.exe",
            "403 rate limited",
            &"a".repeat(64),
        ] {
            let status = update_status(&failed_with(hostile), running)
                .expect("an unrecognised code still renders a sentence");
            assert!(
                !status.text.contains(hostile),
                "{hostile:?} was reflected into user-facing copy"
            );
            assert_eq!(status.tone, Tone::Red);
        }
    }

    /// D-05 / SC2: the version line is the package's own version, and it is a
    /// legal three-integer version at that.
    #[test]
    fn update_version_line_is_the_package_version() {
        assert_eq!(RUNNING_VERSION, env!("CARGO_PKG_VERSION"));
        assert_eq!(
            RUNNING_VERSION.split('.').count(),
            3,
            "the package version must be three integers"
        );
        assert!(RUNNING_VERSION.split('.').all(|p| p.parse::<u32>().is_ok()));
    }

    /// The copy this window shares with the phone, asserted against the
    /// literal sentences in `updates_screen.dart`. If either side is
    /// re-worded, this fails — which is the whole point of naming them.
    #[test]
    fn update_copy_matches_the_phone_vocabulary() {
        assert_eq!(UPDATE_CHECKING, "Checking…");
        assert_eq!(UPDATE_VERIFYING, "Checking the download…");
        assert_eq!(UPDATE_INSTALLING, "Installing…");
        assert_eq!(UPDATE_UP_TO_DATE_PREFIX, "Up to date · ");
        assert_eq!(UPDATE_FAIL_NETWORK, "Download failed — check your connection.");
        assert_eq!(
            UPDATE_FAIL_CHECKSUM,
            "The download didn't match its signature. Nothing was installed."
        );
        assert_eq!(UPDATE_FAIL_DISK, "Not enough space for the download.");
        assert_eq!(
            UPDATE_FAIL_STALE,
            "That version is no longer the latest. Check again."
        );
        // The ellipsis is ONE character (U+2026) and the arrow is U+2192 —
        // never "..." and never "->".
        for s in [UPDATE_CHECKING, UPDATE_VERIFYING, UPDATE_INSTALLING, UPDATE_RESTARTING] {
            assert!(s.ends_with('…'), "{s:?} must end with U+2026");
            assert!(!s.contains("..."), "{s:?} must not spell the ellipsis");
        }
        assert_eq!(UPDATE_TRANSITION_ARROW, " → ");
    }

    /// The settings-side port validation: numeric, in-range, never 0.
    #[test]
    fn settings_port_parse_accepts_valid_rejects_garbage() {
        assert_eq!(parse_port("17777"), Some(17777));
        assert_eq!(parse_port("1"), Some(1));
        assert_eq!(parse_port("65535"), Some(65535));
        assert_eq!(parse_port("0"), None, "port 0 is not a usable listen port");
        assert_eq!(parse_port("65536"), None, "out of u16 range");
        assert_eq!(parse_port("-1"), None);
        assert_eq!(parse_port("abc"), None);
        assert_eq!(parse_port(""), None);
    }

    /// Human paired-at formatting for the device list.
    #[test]
    fn settings_paired_ago_is_humane() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert_eq!(paired_ago(now), "paired today");
        assert_eq!(paired_ago(now - 90_000), "paired yesterday");
        assert_eq!(paired_ago(now - 86_400 * 12), "paired 12 days ago");
        // A future timestamp (clock skew) saturates to "today", never panics.
        assert_eq!(paired_ago(now + 86_400), "paired today");
    }
}
