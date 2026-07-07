//! PIN pairing rules (SPEC §5): 60s expiry, 5 attempts, 5-minute per-IP
//! lockout, discretionary global failure cap.

use std::collections::HashMap;
use std::net::IpAddr;
use std::time::Duration;

use rand::RngExt;
use subtle::ConstantTimeEq;
use tokio::time::Instant;

/// Seconds a displayed PIN stays valid.
pub const PIN_TTL_SECS: u64 = 60;
/// Wrong attempts allowed before lockout.
pub const PIN_MAX_ATTEMPTS: u32 = 5;
/// Per-source-IP lockout duration after exhausting attempts.
pub const LOCKOUT_SECS: u64 = 300;
/// Global failure cap across ALL sources (LAN attackers rotate IPs freely).
pub const GLOBAL_FAIL_CAP: u32 = 20;

/// Result of a PIN verification attempt (maps onto the `authFail` reason
/// enum, SPEC §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinOutcome {
    /// PIN correct: proceed to `complete_pairing`.
    Ok,
    /// Wrong PIN; `attempts_remaining` before lockout (`pinInvalid`).
    WrongPin { attempts_remaining: u32 },
    /// The 60-second window elapsed (`pinExpired`).
    Expired,
    /// Source is locked out; seconds until retry allowed (`lockedOut`).
    LockedOut { retry_after_secs: u64 },
    /// No pairing window is active (`noPairing`).
    NoPairing,
}

/// The currently displayed PIN and its per-window attempt bookkeeping.
///
/// Attempt counts are scoped to the pairing WINDOW (a fresh
/// `begin_pairing` resets them); lockouts and the global failure counter
/// live on [`PinState`] and survive window turnover and reconnects.
struct ActivePin {
    /// Six zero-padded ASCII digits.
    digits: String,
    /// `begin` time + [`PIN_TTL_SECS`] (tokio clock, so paused test time
    /// controls expiry — RESEARCH Pattern 5).
    expires_at: Instant,
    /// Wrong attempts so far, per source IP.
    attempts: HashMap<IpAddr, u32>,
}

/// PIN lifecycle state owned by [`super::AuthManager`] (NEVER by a
/// session type — lockout must survive disconnect/reconnect, threat
/// T-01-19).
pub(crate) struct PinState {
    active: Option<ActivePin>,
    /// Per-source-IP lockout table: locked until the stored instant.
    lockouts: HashMap<IpAddr, Instant>,
    /// Cumulative failures across ALL sources (RESEARCH Open Q2).
    global_failures: u32,
    /// Global lockout (everyone), set when [`GLOBAL_FAIL_CAP`] is reached.
    global_locked_until: Option<Instant>,
}

impl PinState {
    pub(crate) fn new() -> Self {
        Self {
            active: None,
            lockouts: HashMap::new(),
            global_failures: 0,
            global_locked_until: None,
        }
    }

    /// Start a pairing window: fresh CSPRNG 6-digit zero-padded PIN valid
    /// for [`PIN_TTL_SECS`]. Lockout state is intentionally untouched.
    pub(crate) fn begin(&mut self) -> String {
        // rand 0.10 API (RESEARCH Pitfall 3): rng()/random_range, not the
        // pre-0.9 thread_rng()/gen_range names. ThreadRng is a CSPRNG.
        let n: u32 = rand::rng().random_range(0..=999_999);
        let digits = format!("{n:06}");
        self.active = Some(ActivePin {
            digits: digits.clone(),
            expires_at: Instant::now() + Duration::from_secs(PIN_TTL_SECS),
            attempts: HashMap::new(),
        });
        digits
    }

    /// Verify a submitted PIN from `source`, enforcing (in order): global
    /// lockout, per-IP lockout, window presence, expiry, then a
    /// constant-time digit comparison (SPEC §5).
    pub(crate) fn verify(&mut self, pin: &str, source: IpAddr) -> PinOutcome {
        let now = Instant::now();

        // Global cap lockout applies to EVERYONE, any IP.
        if let Some(until) = self.global_locked_until {
            if now < until {
                return PinOutcome::LockedOut { retry_after_secs: (until - now).as_secs() };
            }
            self.global_locked_until = None;
            self.global_failures = 0;
        }

        // Per-source-IP lockout.
        if let Some(&until) = self.lockouts.get(&source) {
            if now < until {
                return PinOutcome::LockedOut { retry_after_secs: (until - now).as_secs() };
            }
            self.lockouts.remove(&source);
        }

        let Some(active) = self.active.as_mut() else {
            return PinOutcome::NoPairing;
        };

        if now >= active.expires_at {
            self.active = None;
            return PinOutcome::Expired;
        }

        // Constant-time comparison over the digit bytes (threat T-01-15):
        // subtle::ConstantTimeEq, never == / eq. Length mismatch yields
        // false without a data-dependent early exit on content.
        if bool::from(pin.as_bytes().ct_eq(active.digits.as_bytes())) {
            self.active = None; // single-use: a verified PIN cannot be replayed
            return PinOutcome::Ok;
        }

        // Failure bookkeeping: per-IP attempts + global counter.
        let attempts = active.attempts.entry(source).or_insert(0);
        *attempts += 1;
        let ip_attempts = *attempts;
        self.global_failures += 1;

        if self.global_failures >= GLOBAL_FAIL_CAP {
            self.global_locked_until = Some(now + Duration::from_secs(LOCKOUT_SECS));
            return PinOutcome::LockedOut { retry_after_secs: LOCKOUT_SECS };
        }

        if ip_attempts >= PIN_MAX_ATTEMPTS {
            self.lockouts.insert(source, now + Duration::from_secs(LOCKOUT_SECS));
            return PinOutcome::LockedOut { retry_after_secs: LOCKOUT_SECS };
        }

        PinOutcome::WrongPin { attempts_remaining: PIN_MAX_ATTEMPTS - ip_attempts }
    }
}

#[cfg(test)]
mod tests {
    //! Paused-time behavior tests (RESEARCH Pattern 5): no real I/O here, so
    //! `#[tokio::test(start_paused = true)]` + `tokio::time::advance` control
    //! the clock — the 60s expiry and 5-minute lockout tests finish in
    //! milliseconds of wall time.

    use std::net::{IpAddr, Ipv4Addr};
    use std::time::Duration;

    use tokio::time::advance;

    use super::super::AuthManager;
    use super::*;

    fn ip(last: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(192, 168, 1, last))
    }

    /// A PIN string guaranteed wrong for any active window: verify_pin
    /// compares fixed-length digit strings, and a 6-char non-digit string
    /// can never equal a generated PIN.
    const WRONG: &str = "xxxxxx";

    #[tokio::test(start_paused = true)]
    async fn begin_pairing_returns_six_zero_padded_digits() {
        let mut auth = AuthManager::new();
        let pin = auth.begin_pairing();
        assert_eq!(pin.len(), 6, "PIN must be exactly 6 chars, got {pin:?}");
        assert!(
            pin.bytes().all(|b| b.is_ascii_digit()),
            "PIN must match ^[0-9]{{6}}$, got {pin:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn correct_pin_within_ttl_is_ok() {
        let mut auth = AuthManager::new();
        let pin = auth.begin_pairing();
        advance(Duration::from_secs(59)).await;
        assert_eq!(auth.verify_pin(&pin, ip(10)), PinOutcome::Ok);
    }

    #[tokio::test(start_paused = true)]
    async fn pin_expires_after_60_seconds() {
        let mut auth = AuthManager::new();
        let pin = auth.begin_pairing();
        advance(Duration::from_secs(61)).await;
        assert_eq!(auth.verify_pin(&pin, ip(10)), PinOutcome::Expired);
    }

    #[tokio::test(start_paused = true)]
    async fn verify_without_active_pairing_is_no_pairing() {
        let mut auth = AuthManager::new();
        assert_eq!(auth.verify_pin("123456", ip(10)), PinOutcome::NoPairing);
    }

    #[tokio::test(start_paused = true)]
    async fn five_wrong_attempts_lock_out_the_source_ip() {
        let mut auth = AuthManager::new();
        let pin = auth.begin_pairing();

        // Attempts 1-4: WrongPin with decreasing attempts_remaining.
        for expected_remaining in (1..PIN_MAX_ATTEMPTS).rev() {
            assert_eq!(
                auth.verify_pin(WRONG, ip(10)),
                PinOutcome::WrongPin { attempts_remaining: expected_remaining },
            );
        }

        // 5th wrong attempt: locked out for LOCKOUT_SECS.
        assert_eq!(
            auth.verify_pin(WRONG, ip(10)),
            PinOutcome::LockedOut { retry_after_secs: LOCKOUT_SECS },
        );

        // Even the CORRECT PIN from the locked-out IP is rejected.
        match auth.verify_pin(&pin, ip(10)) {
            PinOutcome::LockedOut { retry_after_secs } => {
                assert!(
                    retry_after_secs > 0 && retry_after_secs <= LOCKOUT_SECS,
                    "retry_after_secs must be within (0, {LOCKOUT_SECS}], got {retry_after_secs}"
                );
            }
            other => panic!("correct PIN during lockout must be LockedOut, got {other:?}"),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn lockout_is_per_source_ip() {
        let mut auth = AuthManager::new();
        let pin = auth.begin_pairing();

        for _ in 0..PIN_MAX_ATTEMPTS {
            auth.verify_pin(WRONG, ip(10));
        }
        assert!(matches!(
            auth.verify_pin(&pin, ip(10)),
            PinOutcome::LockedOut { .. }
        ));

        // A DIFFERENT IP is unaffected (SPEC section 5: lockout per source IP).
        assert_eq!(auth.verify_pin(&pin, ip(20)), PinOutcome::Ok);
    }

    #[tokio::test(start_paused = true)]
    async fn per_ip_lockout_expires_after_lockout_secs() {
        let mut auth = AuthManager::new();
        auth.begin_pairing();

        for _ in 0..PIN_MAX_ATTEMPTS {
            auth.verify_pin(WRONG, ip(10));
        }
        assert!(matches!(
            auth.verify_pin(WRONG, ip(10)),
            PinOutcome::LockedOut { .. }
        ));

        advance(Duration::from_secs(LOCKOUT_SECS + 1)).await;

        // Lockout elapsed; a fresh pairing window accepts the IP again.
        let pin = auth.begin_pairing();
        assert_eq!(auth.verify_pin(&pin, ip(10)), PinOutcome::Ok);
    }

    #[tokio::test(start_paused = true)]
    async fn twenty_cumulative_failures_lock_out_everyone() {
        let mut auth = AuthManager::new();
        let pin = auth.begin_pairing();

        // 4 failures each from 5 distinct IPs = 20 cumulative failures,
        // with NO single IP reaching its per-IP limit of 5.
        let mut last = PinOutcome::NoPairing;
        for source in 1..=5u8 {
            for _ in 0..4 {
                last = auth.verify_pin(WRONG, ip(source));
            }
        }
        // The failure that reaches the global cap reports lockout.
        assert!(
            matches!(last, PinOutcome::LockedOut { .. }),
            "20th cumulative failure must trip the global cap, got {last:?}"
        );

        // EVERY source is now locked out — even a brand-new IP with the
        // correct PIN (RESEARCH Open Q2: LAN attackers rotate IPs freely).
        assert!(matches!(
            auth.verify_pin(&pin, ip(200)),
            PinOutcome::LockedOut { .. }
        ));
    }
}
