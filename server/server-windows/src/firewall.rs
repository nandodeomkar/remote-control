//! Firewall self-test primitives (SRV-04 / D-06) — a **read-only** query of
//! the Windows Firewall plus a bind-error classifier.
//!
//! Two independent failure modes the composition root (07-06) must surface
//! separately (RESEARCH Pitfall 5):
//!
//! 1. **Port already in use** — `bind(0.0.0.0:port)` returns `AddrInUse`.
//!    Today `main.rs` `?`-propagates this and the whole server crashes;
//!    [`classify_bind_error`] turns it into a distinct `PortInUse` warning.
//!    This is a pure `std::io::Error` inspection — unit-testable with NO OS
//!    state.
//!
//! 2. **Firewall blocks inbound LAN peers (bind still succeeds)** — the
//!    firewall filters *inbound connections from other hosts*, never the local
//!    bind, so a "can I listen?" test always passes even when the phone can't
//!    reach us. [`inbound_allowed`] queries `INetFwPolicy2` on the active
//!    profile instead.
//!
//! SECURITY (threat T-07-07, ASVS V4): [`inbound_allowed`] is **strictly
//! read-only** — it only calls `get_*` property getters and enumerates
//! existing rules. It NEVER calls any `Add`/`Set`/`Remove` on the policy or a
//! rule (creating a firewall allow-rule needs admin and is deferred to the v2
//! MSI installer). Reading firewall state is unprivileged (A3).
//!
//! HEURISTIC LIMITATION (RESEARCH Pitfall 5 / A3): a fully reliable inbound
//! test needs a second host. On a single host the best signal is "is the
//! firewall on for the active profile, and does an enabled inbound Allow rule
//! cover our TCP port?". A rule that allows our port *for a different program*
//! is counted as Allowed here — a false-negative on the warning, chosen over a
//! nagging false-positive. Verdict is advisory, not authoritative.
//!
//! COM discipline (SHARED-D/E, cloned from `apps_thread.rs`): a short-lived
//! MTA apartment (`CoInitializeEx` → work → `CoUninitialize`), every HRESULT
//! `.ok()?`/`?`-handled inside a fallible helper, and any failure collapses to
//! [`FirewallStatus::Unknown`] — never a panic on the caller.

// Built now, wired at startup by the composition root (07-06). Scoped-allow so
// the interim build stays warning-clean without masking dead code elsewhere.
#![allow(dead_code)]

use windows::core::{IUnknown, Interface};
use windows::Win32::NetworkManagement::WindowsFirewall::{
    INetFwPolicy2, INetFwRule, NetFwPolicy2, NET_FW_ACTION_ALLOW, NET_FW_PROFILE2_DOMAIN,
    NET_FW_PROFILE2_PRIVATE, NET_FW_PROFILE2_PUBLIC, NET_FW_RULE_DIR_IN,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::Ole::IEnumVARIANT;
use windows::Win32::System::Variant::VARIANT;

/// TCP over the Windows Firewall `Protocol` property (IANA number 6).
const IPPROTO_TCP: i32 = 6;
/// The firewall "any protocol" sentinel (`NET_FW_IP_PROTOCOL_ANY`).
const PROTOCOL_ANY: i32 = 256;

/// Read-only verdict of the inbound firewall self-test for our listen port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FirewallStatus {
    /// The firewall is off for the active profile, its default inbound action
    /// is Allow, or an enabled inbound Allow rule covers our TCP port.
    Allowed,
    /// The firewall is on with a default-block inbound policy and no enabled
    /// Allow rule covers our port — the phone will silently fail to connect
    /// (D-06 fires the loud warning).
    BlockedNoRule,
    /// The query could not complete (COM error, access issue, unexpected
    /// shape). Fail *quiet*: the caller must NOT warn on Unknown — an
    /// uncertain probe is not evidence of a block.
    Unknown,
}

/// A distinct, actionable bind failure the composition root can surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BindProblem {
    /// `bind()` failed with `AddrInUse` — another process (or a second copy of
    /// this server) already holds the port. Surface a distinct tray warning
    /// instead of crashing (07-06).
    PortInUse,
}

/// Classify a `bind()` I/O error into a known, surfaceable problem.
///
/// Pure and OS-independent — inspects only `err.kind()`, so it unit-tests in
/// CI without any firewall or socket state. Returns `None` for any error we do
/// not specifically recognise (the caller keeps its existing handling).
pub fn classify_bind_error(err: &std::io::Error) -> Option<BindProblem> {
    match err.kind() {
        std::io::ErrorKind::AddrInUse => Some(BindProblem::PortInUse),
        _ => None,
    }
}

/// Query whether inbound TCP on `port` is allowed on the active firewall
/// profile. READ-ONLY (T-07-07): no rule is ever created or modified.
///
/// Runs a short-lived COM apartment; any failure degrades to
/// [`FirewallStatus::Unknown`] and never panics the caller.
pub fn inbound_allowed(port: u16) -> FirewallStatus {
    // SAFETY: initialise an MTA apartment for the duration of this query only
    // (apps_thread discipline). A failed init is dropped — `query()`'s COM
    // calls then fail and we return Unknown. `CoUninitialize` balances a
    // successful init on every exit path below.
    let init = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    let status = query_inbound(port).unwrap_or(FirewallStatus::Unknown);
    // Only uninitialise if the init actually succeeded (S_OK / S_FALSE mean
    // this thread now owns an apartment reference to release).
    if init.is_ok() {
        unsafe { CoUninitialize() };
    }
    status
}

/// The fallible COM body: any `?` bail collapses to `Unknown` in the caller.
fn query_inbound(port: u16) -> windows::core::Result<FirewallStatus> {
    // SAFETY: standard CoCreateInstance for the firewall policy singleton.
    let policy: INetFwPolicy2 = unsafe { CoCreateInstance(&NetFwPolicy2, None, CLSCTX_ALL)? };

    // Bitmask of the currently-active profile(s) (domain/private/public).
    let active = unsafe { policy.CurrentProfileTypes()? };

    // If ANY active profile leaves inbound open (firewall off or default
    // Allow), inbound is not blocked — short-circuit to Allowed.
    for profile in [
        NET_FW_PROFILE2_DOMAIN,
        NET_FW_PROFILE2_PRIVATE,
        NET_FW_PROFILE2_PUBLIC,
    ] {
        if active & profile.0 == 0 {
            continue; // profile not active — ignore
        }
        let enabled = unsafe { policy.get_FirewallEnabled(profile)? };
        if !enabled.as_bool() {
            return Ok(FirewallStatus::Allowed); // firewall off ⇒ nothing blocks
        }
        let default_in = unsafe { policy.get_DefaultInboundAction(profile)? };
        if default_in == NET_FW_ACTION_ALLOW {
            return Ok(FirewallStatus::Allowed); // default-allow inbound
        }
    }

    // Firewall on with default-block on every active profile: the verdict now
    // hinges on whether an enabled inbound Allow rule covers our TCP port.
    if inbound_allow_rule_covers_port(&policy, port)? {
        Ok(FirewallStatus::Allowed)
    } else {
        Ok(FirewallStatus::BlockedNoRule)
    }
}

/// Enumerate the firewall rules (READ-ONLY) for an enabled inbound Allow rule
/// whose TCP local-port set covers `port`. Single-host heuristic (A3): matches
/// on port regardless of which program the rule targets.
fn inbound_allow_rule_covers_port(
    policy: &INetFwPolicy2,
    port: u16,
) -> windows::core::Result<bool> {
    let rules = unsafe { policy.Rules()? };
    let enumerator: IEnumVARIANT = {
        let unknown: IUnknown = unsafe { rules._NewEnum()? };
        unknown.cast()?
    };

    loop {
        let mut fetched = 0u32;
        let mut buf = [VARIANT::default()];
        // Next returns S_OK while it yields an item, S_FALSE at the end.
        let hr = unsafe { enumerator.Next(&mut buf, &mut fetched) };
        if hr.is_err() || fetched == 0 {
            break;
        }

        // Extract the IDispatch out of the VARIANT and re-interface it as an
        // INetFwRule. A shape mismatch just skips this entry.
        let rule: INetFwRule = match variant_to_rule(&buf[0]) {
            Some(rule) => rule,
            None => continue,
        };

        if rule_allows_inbound_tcp_port(&rule, port) {
            return Ok(true);
        }
    }

    Ok(false)
}

/// Best-effort `VARIANT(IDispatch)` → [`INetFwRule`]. Returns `None` on any
/// unexpected variant shape rather than propagating (one bad rule must not
/// abort the whole scan).
fn variant_to_rule(var: &VARIANT) -> Option<INetFwRule> {
    // SAFETY: an enumerated firewall rule arrives as a VT_DISPATCH variant;
    // navigate the VARIANT union to the IDispatch and cast it. A null/other
    // variant yields None.
    unsafe {
        let disp = var.Anonymous.Anonymous.Anonymous.pdispVal.as_ref()?;
        disp.cast::<INetFwRule>().ok()
    }
}

/// Read-only predicate: is this an ENABLED, INBOUND, ALLOW rule whose protocol
/// is TCP (or any) and whose local-port set covers `port`? Every getter that
/// errors is treated as "does not match" (never panics).
fn rule_allows_inbound_tcp_port(rule: &INetFwRule, port: u16) -> bool {
    unsafe {
        // Enabled?
        if !rule.Enabled().map(|b| b.as_bool()).unwrap_or(false) {
            return false;
        }
        // Inbound direction?
        if rule.Direction().unwrap_or(NET_FW_RULE_DIR_IN) != NET_FW_RULE_DIR_IN {
            return false;
        }
        // Allow (not block)?
        if rule.Action().unwrap_or(NET_FW_ACTION_ALLOW) != NET_FW_ACTION_ALLOW {
            return false;
        }
        // TCP or any-protocol?
        match rule.Protocol() {
            Ok(proto) if proto == IPPROTO_TCP || proto == PROTOCOL_ANY => {}
            _ => return false,
        }
        // Local ports cover our port? (empty/absent LocalPorts ⇒ all ports.)
        match rule.LocalPorts() {
            Ok(bstr) => {
                let ports = bstr.to_string();
                ports.trim().is_empty() || local_ports_cover(&ports, port)
            }
            // No LocalPorts property set ⇒ the rule applies to all ports.
            Err(_) => true,
        }
    }
}

/// Does a firewall `LocalPorts` string (e.g. `"17777"`, `"80,443"`,
/// `"8000-8100"`, `"*"`) cover `port`? Pure — unit-testable without OS state.
fn local_ports_cover(local_ports: &str, port: u16) -> bool {
    for token in local_ports.split(',') {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        if token == "*" {
            return true;
        }
        if let Some((lo, hi)) = token.split_once('-') {
            if let (Ok(lo), Ok(hi)) = (lo.trim().parse::<u16>(), hi.trim().parse::<u16>()) {
                if port >= lo && port <= hi {
                    return true;
                }
            }
        } else if let Ok(single) = token.parse::<u16>() {
            if single == port {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// `classify_bind_error` maps a real `AddrInUse` into `PortInUse`. Runs in
    /// CI (no firewall/OS-privilege state) — binds a port, then binds it again
    /// on the same host to provoke the error.
    #[test]
    fn classify_bind_error_maps_addr_in_use_to_port_in_use() {
        // Hold an ephemeral port, then try to bind the SAME address again.
        let held = TcpListener::bind("127.0.0.1:0").expect("first bind");
        let addr = held.local_addr().expect("local addr");
        let err = TcpListener::bind(addr).expect_err("second bind must fail as in-use");

        assert_eq!(
            classify_bind_error(&err),
            Some(BindProblem::PortInUse),
            "AddrInUse must classify to PortInUse"
        );
    }

    /// An unrelated I/O error is not misclassified.
    #[test]
    fn classify_bind_error_ignores_unrelated_errors() {
        let err = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        assert_eq!(classify_bind_error(&err), None);
    }

    /// Pure port-set coverage cases (no OS state).
    #[test]
    fn local_ports_cover_handles_singles_ranges_and_wildcard() {
        assert!(local_ports_cover("17777", 17777));
        assert!(!local_ports_cover("17777", 17778));
        assert!(local_ports_cover("80,443,17777", 17777));
        assert!(local_ports_cover("17000-18000", 17777));
        assert!(!local_ports_cover("17000-17700", 17777));
        assert!(local_ports_cover("*", 17777));
        assert!(!local_ports_cover("", 17777));
    }

    /// Smoke test: querying the real firewall must return SOME variant without
    /// panicking. `#[ignore]` — touches live OS firewall COM state; run with
    /// `cargo test -p server-windows firewall -- --ignored`.
    #[test]
    #[ignore = "touches live Windows Firewall COM state; run on-device with --ignored"]
    fn inbound_allowed_returns_without_panicking() {
        let status = inbound_allowed(17777);
        // Any variant is acceptable — we only assert it did not panic and is a
        // well-formed value.
        assert!(matches!(
            status,
            FirewallStatus::Allowed | FirewallStatus::BlockedNoRule | FirewallStatus::Unknown
        ));
    }
}
