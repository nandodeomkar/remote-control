//! Dedicated COM audio thread (RED stub — GREEN adds the WASAPI poll loop).

/// Command sent from [`crate::executors::media::WinMedia`] to the audio thread.
#[derive(Debug, Clone, PartialEq)]
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

/// Convert an `IAudioEndpointVolume` scalar (0.0..=1.0) to an integer percent.
pub fn pct_from_scalar(_scalar: f32) -> u8 {
    0 // RED stub — GREEN rounds + clamps
}

/// Convert an integer percent (0..=100) to the endpoint scalar (0.0..=1.0).
pub fn scalar_from_pct(_pct: u8) -> f32 {
    0.0 // RED stub — GREEN divides by 100
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
