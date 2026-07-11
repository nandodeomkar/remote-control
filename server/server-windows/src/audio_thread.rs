//! Dedicated COM audio thread — the ONLY place WASAPI/COM objects live
//! (RESEARCH Pattern 2, a clone of [`crate::input_thread`]'s shape).
//!
//! One `std::thread` owns the apartment: `CoInitializeEx(MTA)` runs once here,
//! commands arrive on an `mpsc` channel, and the 250 ms `recv_timeout` poll
//! tick reads the default render endpoint and pushes a `VolumeState` onto the
//! 05-03 `watch` seam whenever it changes (MED-02, D-03 — poll over
//! `RegisterControlChangeNotify` is final per the D-03 research delegation).
//!
//! The `IAudioEndpointVolume` endpoint is re-acquired FRESH every pass so a
//! default-device switch (plugging in headphones) survives with zero
//! notification plumbing (Pitfall 6). EVERY HRESULT failure skips the tick and
//! is dropped with `let _ =` / `?`-to-`None` — never a panic (the
//! send-and-forget rule from `input_thread.rs`).

use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use server_core::transport::VolumeState;
use tokio::sync::watch::Sender;
use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::{
    eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
};

/// Command sent from [`crate::executors::media::WinMedia`] (hot-path,
/// non-blocking mpsc send) to the audio thread.
#[derive(Debug, Clone, PartialEq)]
#[allow(dead_code)] // constructed by WinMedia (05-05 Task 2/3); wired in main.
pub enum AudioCmd {
    /// Set the default render endpoint to exactly N% (absolute, MED-02).
    SetVol(u8),
    /// Toggle system mute.
    MuteToggle,
    /// Nudge volume up one endpoint step.
    StepUp,
    /// Nudge volume down one endpoint step.
    StepDown,
}

/// Convert an `IAudioEndpointVolume` scalar (0.0..=1.0) to an integer percent,
/// rounding to nearest and clamping into 0..=100 (Pitfall 7: `set(55)` must
/// read back 55, not a truncated 54; an out-of-range scalar can never wrap the
/// `u8`).
pub fn pct_from_scalar(scalar: f32) -> u8 {
    (scalar * 100.0).round().clamp(0.0, 100.0) as u8
}

/// Convert an integer percent (0..=100) to the endpoint scalar (0.0..=1.0).
pub fn scalar_from_pct(pct: u8) -> f32 {
    pct as f32 / 100.0
}

/// Acquire the CURRENT default render endpoint's volume interface, fresh.
///
/// Re-acquired every pass so default-device switches survive (Pitfall 6). Any
/// HRESULT failure yields `None` and the caller drops the tick.
fn acquire_endpoint() -> Option<IAudioEndpointVolume> {
    // SAFETY: standard MMDevice → default endpoint → IAudioEndpointVolume
    // activation chain; every fallible COM call is `.ok()?`-dropped to None,
    // never unwrapped. All objects are released when the returned RAII handle
    // (and the locals) drop at end of scope.
    unsafe {
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
        let device = enumerator.GetDefaultAudioEndpoint(eRender, eConsole).ok()?;
        device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None).ok()
    }
}

/// Read the current master volume/mute. `None` on any HRESULT failure.
fn read_state() -> Option<VolumeState> {
    let vol = acquire_endpoint()?;
    // SAFETY: `vol` is a live IAudioEndpointVolume; both reads drop to None on
    // failure (send-and-forget), never panic.
    unsafe {
        let value = pct_from_scalar(vol.GetMasterVolumeLevelScalar().ok()?);
        let muted = vol.GetMute().ok()?.as_bool();
        Some(VolumeState { value, muted })
    }
}

/// Execute one command against a freshly-acquired endpoint. All OS results are
/// `let _ =`-dropped; a failed acquisition skips the command entirely.
fn execute_cmd(cmd: &AudioCmd) {
    let Some(vol) = acquire_endpoint() else {
        return;
    };
    // SAFETY: `vol` is live; the null event-context GUID is documented as
    // valid; every call drops on failure and never panics.
    unsafe {
        match cmd {
            AudioCmd::SetVol(pct) => {
                let _ = vol.SetMasterVolumeLevelScalar(scalar_from_pct(*pct), std::ptr::null());
            }
            AudioCmd::MuteToggle => {
                if let Ok(muted) = vol.GetMute() {
                    let _ = vol.SetMute(!muted.as_bool(), std::ptr::null());
                }
            }
            AudioCmd::StepUp => {
                let _ = vol.VolumeStepUp(std::ptr::null());
            }
            AudioCmd::StepDown => {
                let _ = vol.VolumeStepDown(std::ptr::null());
            }
        }
    }
}

/// Push the current state onto the watch seam iff it changed since `*last`
/// (no-change ticks push nothing — Pitfall 7 comparison-by-value). A failed
/// read simply skips this tick.
fn push_if_changed(tx: &Sender<VolumeState>, last: &mut Option<VolumeState>) {
    let Some(state) = read_state() else {
        return;
    };
    if *last != Some(state) {
        let _ = tx.send(state);
        *last = Some(state);
    }
}

/// Run the WASAPI command + poll loop until every `Sender<AudioCmd>` is
/// dropped. MUST be called on a dedicated `std::thread` (COM apartment
/// affinity): `CoInitializeEx` is called once here and the endpoint objects
/// live and die on this thread, exactly like `Enigo` on the input thread.
#[allow(dead_code)] // spawned by main.rs composition root (05-05 Task 3).
pub fn run_audio_thread(rx: Receiver<AudioCmd>, tx: Sender<VolumeState>) {
    // SAFETY: initialize the MTA apartment once on this thread. A failed init
    // is dropped (`.ok()`); the loop's per-tick acquisitions then simply fail
    // and skip, never panic.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED).ok();
    }

    let mut last: Option<VolumeState> = None;
    loop {
        match rx.recv_timeout(Duration::from_millis(250)) {
            // A command: execute it, then immediately re-read + push so the
            // client sees the authoritative post-command state without waiting
            // for the next tick (D-04 drag-ignore makes the self-echo harmless).
            Ok(cmd) => {
                execute_cmd(&cmd);
                push_if_changed(&tx, &mut last);
            }
            // Poll tick: read state, push iff it changed externally.
            Err(RecvTimeoutError::Timeout) => {
                push_if_changed(&tx, &mut last);
            }
            // Every producer dropped — the server is shutting down.
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    // SAFETY: balance the CoInitializeEx above on thread exit (best-effort).
    unsafe {
        CoUninitialize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pitfall 7: every 0..=100 percent survives the scalar round trip with
    /// zero drift — `set_volume(55)` must read back exactly 55, not 54.
    #[test]
    fn pct_scalar_round_trip_is_lossless() {
        for pct in 0u8..=100 {
            let back = pct_from_scalar(scalar_from_pct(pct));
            assert_eq!(back, pct, "percent {pct} drifted to {back} across the round trip");
        }
    }

    /// Out-of-range scalars from the endpoint clamp into 0..=100 (never wrap /
    /// overflow the `u8`).
    #[test]
    fn pct_from_scalar_clamps_out_of_range() {
        assert_eq!(pct_from_scalar(1.2), 100, "scalar > 1.0 clamps to 100");
        assert_eq!(pct_from_scalar(-0.1), 0, "scalar < 0.0 clamps to 0");
    }
}
