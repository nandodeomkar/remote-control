//! UDP discovery beacon broadcaster (CONN-01, `protocol/BEACON.md`).
//!
//! Every [`BEACON_INTERVAL`] the beacon datagram is sent to each up,
//! non-loopback IPv4 interface's subnet-directed broadcast address on the
//! beacon port ([`DEFAULT_BEACON_PORT`] unless the composition root
//! overrides it). A single `255.255.255.255` send would exit only ONE
//! interface chosen by the routing table, so per-interface directed
//! broadcast is mandatory; interfaces are re-enumerated on every tick
//! because adapters churn under VPN/WSL/Hyper-V.
//!
//! Identity (device name + machine GUID) is OS-specific and injected by the
//! composition root via [`BeaconIdentity`] — this crate keeps its
//! zero-Windows-deps invariant (`if-addrs` is cross-platform).
//!
//! SECURITY (threat T-03-01): the payload carries EXACTLY the keys
//! `v`/`app`/`name`/`guid`/`port`/`proto` — no PIN, token, or hash ever
//! enters [`encode_beacon`]. The beacon is unauthenticated broadcast
//! output; a spoofed beacon harvests nothing (challenge-response, SPEC §4).

use std::net::Ipv4Addr;
use std::time::Duration;

/// Beacon send cadence (BEACON.md: every 2 seconds).
pub const BEACON_INTERVAL: Duration = Duration::from_secs(2);

/// Default UDP destination port for beacon datagrams (BEACON.md).
/// Env-overridable by the composition root via `RC_BEACON_PORT`.
pub const DEFAULT_BEACON_PORT: u16 = 17778;

/// The PC identity carried by every beacon.
///
/// `guid` identifies the PC across IP changes (D-07 disambiguation);
/// `ws_port` is the RESOLVED WebSocket port — it travels IN the beacon so
/// ws-port changes need no client update.
pub struct BeaconIdentity {
    /// Human-readable PC name (`COMPUTERNAME` on Windows), ≤ 64 chars.
    pub name: String,
    /// Stable machine GUID, ≤ 64 chars, non-empty.
    pub guid: String,
    /// The WebSocket port clients should connect to.
    pub ws_port: u16,
}

/// Encode the beacon payload (BEACON.md wire format) as a UTF-8 JSON string.
///
/// Identity never changes at runtime — callers encode ONCE at task start.
pub fn encode_beacon(identity: &BeaconIdentity) -> String {
    let _ = identity;
    todo!("implemented in 03-01 GREEN")
}

/// Compute the subnet-directed broadcast address for an interface.
///
/// Uses the interface-provided broadcast address when present, else
/// `ip | !netmask`.
pub(crate) fn directed_broadcast(
    ip: Ipv4Addr,
    netmask: Ipv4Addr,
    broadcast: Option<Ipv4Addr>,
) -> Ipv4Addr {
    let _ = (ip, netmask, broadcast);
    todo!("implemented in 03-01 GREEN")
}

/// Broadcast the beacon forever: bind an ephemeral UDP socket with
/// `SO_BROADCAST`, then every [`BEACON_INTERVAL`] re-enumerate the up,
/// non-loopback IPv4 interfaces and send the payload to each one's directed
/// broadcast address at `beacon_port`. Per-tick errors never kill the loop
/// (listener.rs never-die posture).
pub async fn run_beacon(identity: BeaconIdentity, beacon_port: u16) {
    let _ = (identity, beacon_port);
    todo!("implemented in 03-01 GREEN")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// Fixture path resolved from the crate manifest, immune to test cwd —
    /// the same idiom as `tests/fixtures.rs` (`FIXTURES_ROOT`).
    const VALID_FIXTURE: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/fixtures/beacon/01-valid.json"
    );

    /// Identity fields chosen to match `01-valid.json` exactly.
    fn fixture_identity() -> BeaconIdentity {
        BeaconIdentity {
            name: "OMKAR-LAPTOP".to_string(),
            guid: "9f3c-test-guid".to_string(),
            ws_port: 17777,
        }
    }

    /// Test 1 (encode): the encoded beacon, parsed as JSON, equals the
    /// `wire` object of the shared fixture (field order insignificant).
    #[test]
    fn encode_beacon_matches_valid_fixture_wire() {
        let fixture: Value = serde_json::from_str(
            &std::fs::read_to_string(VALID_FIXTURE).expect("read 01-valid.json"),
        )
        .expect("01-valid.json is valid JSON");

        let encoded: Value = serde_json::from_str(&encode_beacon(&fixture_identity()))
            .expect("encoded beacon parses as JSON");

        assert_eq!(encoded, fixture["wire"]);
    }

    /// Test 2 (broadcast math): /24 and /16 host-bit fill, plus the
    /// interface-provided broadcast address passing through unchanged.
    #[test]
    fn directed_broadcast_math() {
        assert_eq!(
            directed_broadcast(
                Ipv4Addr::new(192, 168, 1, 7),
                Ipv4Addr::new(255, 255, 255, 0),
                None
            ),
            Ipv4Addr::new(192, 168, 1, 255)
        );
        assert_eq!(
            directed_broadcast(
                Ipv4Addr::new(172, 16, 5, 9),
                Ipv4Addr::new(255, 255, 0, 0),
                None
            ),
            Ipv4Addr::new(172, 16, 255, 255)
        );
        // When the interface provides its broadcast address, it wins as-is.
        assert_eq!(
            directed_broadcast(
                Ipv4Addr::new(192, 168, 1, 7),
                Ipv4Addr::new(255, 255, 255, 0),
                Some(Ipv4Addr::new(192, 168, 1, 42))
            ),
            Ipv4Addr::new(192, 168, 1, 42)
        );
    }

    /// Test 3 (no secrets): the payload contains EXACTLY the six public
    /// keys and nothing else (threat T-03-01).
    #[test]
    fn beacon_payload_contains_exactly_the_public_keys() {
        let encoded: Value = serde_json::from_str(&encode_beacon(&fixture_identity()))
            .expect("encoded beacon parses as JSON");
        let obj = encoded.as_object().expect("beacon is a JSON object");

        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["app", "guid", "name", "port", "proto", "v"]);
    }

    /// Test 4 (constants): contract values from BEACON.md.
    #[test]
    fn beacon_constants_match_contract() {
        assert_eq!(BEACON_INTERVAL, Duration::from_secs(2));
        assert_eq!(DEFAULT_BEACON_PORT, 17778);
    }
}
