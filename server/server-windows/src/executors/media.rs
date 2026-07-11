//! Real `Media` executor (MED-01/MED-02): a sync trait impl holding ONLY the
//! two `Send + Sync` channel senders — identical shape to
//! [`crate::executors::mouse_keys::EnigoMouseKeys`].
//!
//! Media transport keys route through the input thread (`VK_MEDIA_*` are
//! system-wide by SMTC design); volume ops route through the dedicated COM
//! audio thread. Every send is `let _ =` send-and-forget: a closed channel
//! drops the frame, never blocks the session read task and never runs COM on a
//! tokio worker (Pitfall 5).

use std::sync::mpsc::Sender;

use server_core::executors::{KeyCode, Media};

use crate::audio_thread::AudioCmd;
use crate::input_thread::Cmd;

/// Windows `Media` executor: `input_tx` carries media transport taps to the
/// input thread; `audio_tx` carries volume/mute commands to the audio thread.
pub struct WinMedia {
    input_tx: Sender<Cmd>,
    audio_tx: Sender<AudioCmd>,
}

impl WinMedia {
    /// Wrap the input-thread and audio-thread senders from the composition root.
    pub fn new(input_tx: Sender<Cmd>, audio_tx: Sender<AudioCmd>) -> Self {
        Self { input_tx, audio_tx }
    }

    /// Tap a media transport key (no modifiers) on the input thread.
    fn tap(&self, code: &str) {
        let _ = self.input_tx.send(Cmd::KeyTap(KeyCode(code.into()), vec![]));
    }
}

impl Media for WinMedia {
    fn play_pause(&self) {
        self.tap("MediaPlayPause");
    }
    fn next(&self) {
        self.tap("MediaNextTrack");
    }
    fn prev(&self) {
        self.tap("MediaPrevTrack");
    }
    fn vol_up(&self) {
        let _ = self.audio_tx.send(AudioCmd::StepUp);
    }
    fn vol_down(&self) {
        let _ = self.audio_tx.send(AudioCmd::StepDown);
    }
    fn mute(&self) {
        let _ = self.audio_tx.send(AudioCmd::MuteToggle);
    }
    fn set_volume(&self, pct: u8) {
        let _ = self.audio_tx.send(AudioCmd::SetVol(pct));
    }
}
