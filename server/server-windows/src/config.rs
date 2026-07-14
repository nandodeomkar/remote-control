//! Persistent server config (SRV-03, D-01): serde structs + `load`/`save`
//! for `%APPDATA%/RemoteControl/config.toml`.
//!
//! All file I/O lives HERE in server-windows — server-core keeps its
//! zero-Windows-deps invariant. The auth store is seeded at startup via
//! [`server_core::auth::AuthManager::from_paired`] fed by
//! [`to_paired_devices`]; the composition root re-serializes the file on
//! every paired-set change via [`from_auth`] + [`save`].
//!
//! SECURITY (T-07-26 / T-01-08, ASVS V2): the file stores each paired
//! device's SHA-256 token hash as 64 lowercase hex chars ONLY — there is
//! deliberately NO raw-token field on any struct in this module (asserted
//! by the `config_stores_hash_hex_only_never_a_raw_token` test).
//!
//! SECURITY (T-07-27, ASVS V5): the load path is fail-safe end to end — a
//! corrupt/partial file yields [`Config::default`], a malformed hash entry
//! is skipped with a warn, an out-of-range/garbage port drops to `None`
//! without failing the rest of the file, and missing fields default. NEVER
//! a panic (a hand-edited config must not crash the server; T-07-28's
//! local-tamper case is accepted — per-user %APPDATA% perms limit reach).

use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize};
use server_core::auth::PairedDevice;

/// Default WebSocket port. Lowest precedence in [`resolve_port`]
/// (`RC_PORT` env > `Config::port` > this).
pub const DEFAULT_PORT: u16 = 17777;

/// The persisted server settings (SPEC config.toml schema): device name,
/// port, autostart + clipboard-sync toggles, and the paired-device records.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Overrides the `COMPUTERNAME`-derived beacon/device name when set.
    pub device_name: Option<String>,
    /// Configured WebSocket port — middle precedence (`RC_PORT` env wins).
    /// Deserialized leniently: out-of-range/garbage values drop to `None`
    /// WITHOUT failing the rest of the file (T-07-27).
    #[serde(deserialize_with = "de_port")]
    pub port: Option<u16>,
    /// Launch-at-login toggle (SRV-02; the 07-08 settings window drives it).
    pub autostart: bool,
    /// Gates the clip thread's auto-sync push (CLIP-03; RESEARCH Open Q5).
    pub clipboard_sync: bool,
    /// Paired devices — hash hex ONLY, never raw tokens (T-07-26).
    pub paired: Vec<PairedDeviceCfg>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            device_name: None,
            port: None,
            autostart: false,
            // Default ON: Phase 6 shipped clipboard auto-sync always-on; a
            // fresh install (no config.toml yet) must not silently regress
            // it. The 07-08 settings toggle is the opt-out.
            clipboard_sync: true,
            paired: Vec::new(),
        }
    }
}

/// One `[[paired]]` record: the phone's name, its token hash as hex, and the
/// pairing time. Mirrors [`PairedDevice`] with the hash hex-encoded — and,
/// like it, carries NO raw-token field (T-07-26).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairedDeviceCfg {
    /// The phone's `hello.device` name recorded at pairing (D-04).
    pub name: String,
    /// 64 lowercase hex chars — SHA-256 of the raw token, the ONLY persisted
    /// token form (T-01-08).
    pub hash: String,
    /// Unix seconds when this device completed pairing.
    pub paired_at: u64,
}

/// Lenient port field codec (T-07-27): only an integer in `1..=65535`
/// survives; a garbage type, out-of-range value, or port `0` (not a usable
/// listen port) drops to `None` WITHOUT erroring the whole file — a
/// hand-edited port must never nuke the paired list.
fn de_port<'de, D>(d: D) -> Result<Option<u16>, D::Error>
where
    D: Deserializer<'de>,
{
    let _ = d;
    todo!("07-07 Task 1 GREEN: lenient port deserializer")
}

/// `%APPDATA%/RemoteControl/config.toml` via `dirs::config_dir()` (RESEARCH
/// A5: Roaming, the spec's `%APPDATA%`). A missing known folder degrades to
/// a relative path — never a panic.
pub fn config_path() -> PathBuf {
    todo!("07-07 Task 1 GREEN: config_path")
}

/// Read + parse the config file. Missing file (the normal first run) or any
/// read/parse error yields [`Config::default`] — never a panic (T-07-27).
pub fn load() -> Config {
    todo!("07-07 Task 1 GREEN: load")
}

/// Pure parse seam for [`load`] (unit-testable without disk): a corrupt or
/// partial document yields [`Config::default`] with a warn.
pub fn parse(text: &str) -> Config {
    let _ = text;
    todo!("07-07 Task 1 GREEN: parse")
}

/// Pure serialize seam for [`save`] (unit-testable without disk).
/// Serialization failure warns and yields an empty string ([`save`] skips
/// the write rather than truncating a good file).
pub fn to_toml(cfg: &Config) -> String {
    let _ = cfg;
    todo!("07-07 Task 1 GREEN: to_toml")
}

/// Serialize + write the config file, creating the parent directory. Every
/// failure is log-and-continue — persistence must never crash the server.
pub fn save(cfg: &Config) {
    let _ = cfg;
    todo!("07-07 Task 1 GREEN: save")
}

/// Decode the `[[paired]]` records into [`PairedDevice`]s for
/// [`server_core::auth::AuthManager::from_paired`]. A malformed hash (bad
/// hex OR wrong length) SKIPS that entry with a warn — the remaining valid
/// devices still load (T-07-27).
pub fn to_paired_devices(cfg: &Config) -> Vec<PairedDevice> {
    let _ = cfg;
    todo!("07-07 Task 1 GREEN: to_paired_devices")
}

/// Build a [`Config`] from the live auth records + current settings — the
/// save path used by the composition root's change-signal subscription
/// (D-01/D-05). Hash is hex-encoded; nothing else of the token exists to
/// persist (T-07-26).
pub fn from_auth(
    records: &[PairedDevice],
    device_name: Option<String>,
    port: Option<u16>,
    autostart: bool,
    clipboard_sync: bool,
) -> Config {
    let _ = (records, device_name, port, autostart, clipboard_sync);
    todo!("07-07 Task 1 GREEN: from_auth")
}

/// Resolved WebSocket port: `RC_PORT` env > `Config::port` > [`DEFAULT_PORT`]
/// (SPEC precedence). An unparseable/zero env value warns and falls through
/// — never a panic (T-07-27).
pub fn resolve_port(env_port: Option<&str>, cfg: &Config) -> u16 {
    let _ = (env_port, cfg);
    todo!("07-07 Task 1 GREEN: resolve_port")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_config() -> Config {
        Config {
            device_name: Some("Omkar-PC".to_owned()),
            port: Some(19000),
            autostart: true,
            clipboard_sync: false,
            paired: vec![
                PairedDeviceCfg {
                    name: "Pixel".to_owned(),
                    hash: "11".repeat(32),
                    paired_at: 1_700_000_000,
                },
                PairedDeviceCfg {
                    name: "Galaxy".to_owned(),
                    hash: "ab".repeat(32),
                    paired_at: 1_700_000_100,
                },
            ],
        }
    }

    /// A well-formed config round-trips Config → toml → Config unchanged.
    #[test]
    fn config_round_trips_through_toml() {
        let cfg = sample_config();
        let text = to_toml(&cfg);
        assert!(!text.is_empty(), "a well-formed config serializes");
        assert_eq!(parse(&text), cfg, "round trip preserves every field");
    }

    /// T-07-26: the serialized file carries the hash key + hex only — no
    /// raw-token field exists on any struct to leak.
    #[test]
    fn config_stores_hash_hex_only_never_a_raw_token() {
        let records = vec![PairedDevice::new([0x5Au8; 32], "Pixel".to_owned(), 42)];
        let cfg = from_auth(&records, None, None, false, true);
        let text = to_toml(&cfg);
        assert!(
            text.contains(&"5a".repeat(32)),
            "the SHA-256 hash serializes as 64 lowercase hex chars"
        );
        assert!(text.contains("hash"), "the persisted key is `hash`");
        assert!(
            !text.to_lowercase().contains("token"),
            "no raw-token field may ever serialize (T-01-08)"
        );
    }

    /// T-07-27: a bad-hex (or wrong-length) paired entry is skipped with the
    /// remaining valid entries still loading — never fatal.
    #[test]
    fn config_malformed_hash_entry_is_skipped_not_fatal() {
        let good_hash = "ab".repeat(32);
        let text = format!(
            r#"
[[paired]]
name = "Good"
hash = "{good_hash}"
paired_at = 1

[[paired]]
name = "BadHex"
hash = "zz-not-hex"
paired_at = 2

[[paired]]
name = "WrongLength"
hash = "abcd"
paired_at = 3
"#
        );
        let cfg = parse(&text);
        assert_eq!(cfg.paired.len(), 3, "parse itself keeps every entry");
        let devices = to_paired_devices(&cfg);
        assert_eq!(devices.len(), 1, "only the valid-hash entry survives decode");
        assert_eq!(devices[0].name, "Good");
        assert_eq!(devices[0].hash, [0xABu8; 32]);
        assert_eq!(devices[0].paired_at, 1);
    }

    /// T-07-27: a corrupt/partial/empty file yields defaults — and the
    /// defaults are the safe ones (clip sync ON, nothing paired).
    #[test]
    fn config_corrupt_file_yields_defaults_never_panics() {
        assert_eq!(parse("not [ valid toml ]["), Config::default());
        assert_eq!(parse(""), Config::default());
        let d = Config::default();
        assert!(d.clipboard_sync, "clipboard sync defaults ON (Phase-6 behavior kept)");
        assert!(d.paired.is_empty());
        assert_eq!(d.port, None);
        assert!(!d.autostart);
    }

    /// T-07-27: an out-of-range/garbage/zero port drops to None WITHOUT
    /// nuking the rest of the file (the paired list survives).
    #[test]
    fn config_bad_port_is_dropped_but_rest_survives() {
        let good_hash = "ab".repeat(32);
        let text = format!(
            "port = 99999\n\n[[paired]]\nname = \"Pixel\"\nhash = \"{good_hash}\"\npaired_at = 7\n"
        );
        let cfg = parse(&text);
        assert_eq!(cfg.port, None, "out-of-range port drops to None");
        assert_eq!(cfg.paired.len(), 1, "a bad port must not nuke the paired list");

        assert_eq!(parse("port = \"abc\"").port, None, "garbage-typed port drops");
        assert_eq!(parse("port = 0").port, None, "port 0 is not a usable listen port");
        assert_eq!(parse("port = 19000").port, Some(19000), "a valid port survives");
    }

    /// SPEC precedence: RC_PORT env > config.port > DEFAULT_PORT — and an
    /// invalid env value falls through instead of panicking.
    #[test]
    fn config_port_precedence_env_over_config_over_default() {
        let cfg = Config { port: Some(19000), ..Config::default() };
        assert_eq!(resolve_port(Some("18000"), &cfg), 18000, "env wins over config");
        assert_eq!(resolve_port(None, &cfg), 19000, "config wins over default");
        assert_eq!(resolve_port(None, &Config::default()), DEFAULT_PORT, "default is last");
        assert_eq!(
            resolve_port(Some("garbage"), &cfg),
            19000,
            "invalid env falls through to config, never panics"
        );
        assert_eq!(
            resolve_port(Some("0"), &Config::default()),
            DEFAULT_PORT,
            "env port 0 falls through to default"
        );
    }

    /// The save-path builder and load-path decoder are inverses: records fed
    /// through from_auth → to_paired_devices come back byte-identical.
    #[test]
    fn config_from_auth_round_trips_hashes() {
        let records = vec![
            PairedDevice::new([1u8; 32], "Pixel".to_owned(), 1),
            PairedDevice::new([2u8; 32], "Galaxy".to_owned(), 2),
        ];
        let cfg = from_auth(&records, Some("PC".to_owned()), Some(19000), true, false);
        assert_eq!(cfg.device_name.as_deref(), Some("PC"));
        assert_eq!(cfg.port, Some(19000));
        assert!(cfg.autostart);
        assert!(!cfg.clipboard_sync);
        assert_eq!(to_paired_devices(&cfg), records, "hashes survive the round trip");
    }
}
