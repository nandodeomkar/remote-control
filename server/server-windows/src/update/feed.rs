//! Release-feed client — what "latest" is, and which file belongs to it.
//!
//! This file is where D-14 becomes physical. [`RELEASES_API`] and the three
//! asset-name prefixes are `const`s **in this crate**. `server-core`, which
//! owns the codec that decodes attacker-reachable JSON, has no path to them:
//! it cannot read them, cannot override them, and cannot be talked into
//! pointing this module somewhere else. The only value that ever crosses from
//! the wire into the update subsystem is a version string.
//!
//! Everything testable is factored OUT of the network call, the same rule
//! `clip_thread` follows for the OS call: [`parse_release`], [`strip_digest`]
//! and [`resolve_asset`] are pure and unit-tested against the shared fixtures
//! in `protocol/fixtures/update/`, with no socket anywhere near them.
//!
//! # Two rules that are easy to get wrong
//!
//! **Never cache a resolved `browser_download_url` across a run.** GitHub
//! 302s it to a *different* host (`release-assets.githubusercontent.com`)
//! with a time-limited signed query. A URL resolved at check time and reused
//! at apply time is a URL that has expired. Resolve immediately before each
//! download.
//!
//! **A missing digest is a refusal, not a shortcut.** GitHub only began
//! populating per-asset `digest` on 2025-06-03, so `null` is a real state,
//! not a hypothetical. It means the one integrity check standing between a
//! tampered asset and an installer running with the owner's privileges is
//! absent — so [`resolve_asset`] returns [`UpdateError::Checksum`] and
//! nothing is downloaded (D-15).

use std::time::Duration;

use serde::Deserialize;

use super::UpdateError;

/// The release feed, compiled in (D-14). This string is the server's own
/// authority over what it downloads; it is never read from config, never
/// read from the wire, and must not appear anywhere under
/// `server/server-core/`.
///
/// Anonymous — NO `Authorization` header is ever sent (D-01). The cost is
/// the 60-requests/hour/IP anonymous rate limit, which a once-a-day check
/// does not come close to (see [`map_ureq`]).
const RELEASES_API: &str =
    "https://api.github.com/repos/nandodeomkar/remote-control-releases/releases/latest";

/// Windows setup exe: `RemoteControl-Setup-v1.5.0.exe`.
const SETUP_ASSET_PREFIX: &str = "RemoteControl-Setup-v";

/// Android APK: `RemoteControl-v1.5.0.apk`.
const APK_ASSET_PREFIX: &str = "RemoteControl-v";

/// Browser extension zip: `RemoteControl-Extension-v1.5.0.zip`.
const EXT_ASSET_PREFIX: &str = "RemoteControl-Extension-v";

/// The three prefixes are disjoint by construction — `RemoteControl-Setup-v`
/// and `RemoteControl-Extension-v` both diverge from `RemoteControl-v` at the
/// character after `RemoteControl-`, so the APK prefix cannot swallow the
/// other two. [`resolve_asset`] relies on that: it demands exactly one match.
const _: () = {
    assert!(!SETUP_ASSET_PREFIX.as_bytes()[14].is_ascii_lowercase());
    assert!(!EXT_ASSET_PREFIX.as_bytes()[14].is_ascii_lowercase());
};

/// The one release the feed calls "latest", reduced to the five values that
/// matter. Everything else the API returns is ignored — the response is
/// large, and the API IS the manifest (D-03): no second file to drift.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    /// Semver with any leading `v` already stripped: `1.5.0`, not `v1.5.0`.
    pub version: String,
    pub assets: Vec<Asset>,
}

/// One published file in a release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
    /// The `browser_download_url`. Time-sensitive — see the module header.
    pub url: String,
    pub size_bytes: u64,
    /// The sha256 digest with the `sha256:` prefix ALREADY STRIPPED and
    /// lowercased. `None` means the API returned `null` or omitted it, or
    /// carried something that was not a sha256 — all three are refusals.
    pub sha256: Option<String>,
}

// ── The wire shape, as the API actually sends it ────────────────────────────
// Field names confirmed live against a public repo's releases/latest on
// 2026-08-01 and pinned by protocol/fixtures/update/11-releases-latest.json.
// serde ignores unknown fields by default, which is what we want: the real
// response carries ~40 more keys and none of them are our business.

#[derive(Deserialize)]
struct ApiRelease {
    tag_name: String,
    #[serde(default)]
    assets: Vec<ApiAsset>,
}

#[derive(Deserialize)]
struct ApiAsset {
    name: String,
    browser_download_url: String,
    size: u64,
    #[serde(default)]
    digest: Option<String>,
}

/// Parse a `releases/latest` body into a [`Release`]. Pure — no I/O.
///
/// A body that will not deserialise is [`UpdateError::Network`]: from the
/// user's side "the feed gave us something we could not read" and "the feed
/// was unreachable" are the same event, and the vocabulary has no `parse`
/// code (D-11 is closed).
pub fn parse_release(body: &str) -> Result<Release, UpdateError> {
    let api: ApiRelease = serde_json::from_str(body).map_err(|e| {
        tracing::warn!("update: releases feed body did not parse: {e}");
        UpdateError::Network
    })?;

    Ok(Release {
        version: api.tag_name.strip_prefix('v').unwrap_or(&api.tag_name).to_string(),
        assets: api
            .assets
            .into_iter()
            .map(|a| Asset {
                name: a.name,
                url: a.browser_download_url,
                size_bytes: a.size,
                sha256: strip_digest(a.digest.as_deref()),
            })
            .collect(),
    })
}

/// `Some("sha256:<64 hex>")` → `Some("<64 lowercase hex>")`; everything else
/// → `None`.
///
/// Deliberately strict. `None` is returned for a null digest, for a non-sha256
/// algorithm prefix (`sha1:`, `md5:` — a weaker hash is not a hash we accept),
/// for a wrong length, and for non-hex characters. Every one of those becomes
/// a hard refusal upstream, so a permissive parser here would be a silently
/// disabled integrity check.
pub fn strip_digest(raw: Option<&str>) -> Option<String> {
    let hex = raw?.strip_prefix("sha256:")?;
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some(hex.to_ascii_lowercase())
}

/// Find the single asset whose name starts with `prefix`.
///
/// Two distinct refusals, on purpose:
/// - **Zero or more than one match** is [`UpdateError::Installer`]. The
///   release is malformed — a publish went wrong — and blaming the network
///   would send the user to check their WiFi for a problem on the server side.
/// - **A matched asset with no usable digest** is [`UpdateError::Checksum`]
///   (D-15). This is the hard refusal: it fires here, at resolve time, so
///   that nothing is ever downloaded for an asset we could not have verified
///   anyway.
pub fn resolve_asset<'a>(rel: &'a Release, prefix: &str) -> Result<&'a Asset, UpdateError> {
    let mut matches = rel.assets.iter().filter(|a| a.name.starts_with(prefix));
    let Some(found) = matches.next() else {
        tracing::warn!("update: release {} has no asset matching {prefix}", rel.version);
        return Err(UpdateError::Installer);
    };
    if matches.next().is_some() {
        tracing::warn!(
            "update: release {} has more than one asset matching {prefix}",
            rel.version
        );
        return Err(UpdateError::Installer);
    }
    if found.sha256.is_none() {
        // D-15: absent digest ⇒ refuse. Never "download it anyway and trust
        // the TLS transport".
        tracing::warn!(
            "update: asset {} carries no usable sha256 digest — refusing",
            found.name
        );
        return Err(UpdateError::Checksum);
    }
    Ok(found)
}

/// The agent used for feed GETs.
///
/// RESEARCH Pitfall 1: **every ureq timeout defaults to `None`.** Without
/// these two, a black-holed socket parks the update thread forever — the
/// phone sits on `downloading` with no terminal frame ever arriving, and the
/// `busy` guard never clears, so every retry is refused until the server is
/// quit from the tray. 10 s global is generous for a small JSON body; a
/// response slower than that is a broken network, not a slow one.
pub fn feed_agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(10)))
        .timeout_connect(Some(Duration::from_secs(5)))
        // GitHub requires a User-Agent on API requests.
        .user_agent("RemoteControl-Updater")
        .build()
        .into()
}

/// GET the feed and parse it. Sends no `Authorization` header (D-01).
pub fn fetch_latest(agent: &ureq::Agent) -> Result<Release, UpdateError> {
    let mut res = agent.get(RELEASES_API).call().map_err(map_ureq)?;
    // A 1 MiB cap is a DoS belt, not a functional constraint: a real
    // releases/latest body is a few KB (T-12-16).
    let body = res
        .body_mut()
        .with_config()
        .limit(1 << 20)
        .read_to_string()
        .map_err(map_ureq)?;
    parse_release(&body)
}

/// Collapse every ureq failure into [`UpdateError::Network`].
///
/// `http_status_as_error` defaults to `true`, so a 4xx/5xx arrives as
/// `Err(StatusCode(n))` rather than as a response — including the anonymous
/// rate limiter's 403 and a 429 (RESEARCH Pitfall 2). D-11 has no
/// `ratelimit` code and the vocabulary is closed, so all of it is `network`
/// to the user.
///
/// The **log lines differ** even though the user-facing copy does not. Note
/// that the phone and the PC usually sit behind the same NAT and therefore
/// share the 60-requests/hour anonymous budget, so a debugging session that
/// hammers retry can exhaust it for both — a case that is impossible to
/// diagnose from "couldn't check" alone.
pub fn map_ureq(e: ureq::Error) -> UpdateError {
    match e {
        ureq::Error::StatusCode(code) => {
            tracing::warn!(
                "update: feed returned HTTP {code} (403/429 here is the anonymous \
                 rate limiter — 60 req/hour/IP, shared with the phone behind the same NAT)"
            );
        }
        other => {
            tracing::warn!("update: feed transport failure: {other}");
        }
    }
    UpdateError::Network
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fixture root resolved from the crate manifest — immune to test cwd
    /// (the `FIXTURES_ROOT` idiom from server-core's `tests/fixtures.rs`).
    const LATEST: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/fixtures/update/11-releases-latest.json"
    );
    const NULL_DIGEST: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/fixtures/update/12-releases-latest-null-digest.json"
    );

    /// These two fixtures are SPECIAL CASES — they have no `wire`/`expect`
    /// envelope, and the captured API response is nested under `response`.
    /// Hence a bespoke loader rather than the shared wire harness.
    fn load_response(path: &str) -> String {
        let raw = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
        let v: serde_json::Value = serde_json::from_str(&raw).expect("fixture is JSON");
        v.get("response")
            .expect("fixture has a `response` key")
            .to_string()
    }

    #[test]
    fn feed_parse_matches_the_shared_fixture() {
        let rel = parse_release(&load_response(LATEST)).expect("fixture parses");

        // tag_name is "v1.5.0"; the leading v is stripped so the value can go
        // straight into the D-26 comparator.
        assert_eq!(rel.version, "1.5.0");
        assert_eq!(rel.assets.len(), 3);

        let apk = resolve_asset(&rel, APK_ASSET_PREFIX).expect("apk resolves");
        assert_eq!(apk.name, "RemoteControl-v1.5.0.apk");
        assert_eq!(apk.size_bytes, 69630935);
        assert_eq!(
            apk.sha256.as_deref(),
            Some("3333cf18753033586c895652cd3cff6cd25c00b2e713a241a01a388c26e3f730")
        );

        let setup = resolve_asset(&rel, SETUP_ASSET_PREFIX).expect("setup resolves");
        assert_eq!(setup.name, "RemoteControl-Setup-v1.5.0.exe");
        assert_eq!(setup.size_bytes, 5177240);
        assert_eq!(
            setup.sha256.as_deref(),
            Some("74dcced8f351704c0e18c409cc63064ad5c72894e937f9915e3ab38c37027af1")
        );
        assert!(setup.url.ends_with("/RemoteControl-Setup-v1.5.0.exe"));

        let ext = resolve_asset(&rel, EXT_ASSET_PREFIX).expect("extension resolves");
        assert_eq!(ext.name, "RemoteControl-Extension-v1.5.0.zip");
        assert_eq!(ext.size_bytes, 13454);
        assert_eq!(
            ext.sha256.as_deref(),
            Some("19266fa182418190e8d6ae1339a1ce9098b2d7c184ace70b555b2a03343ca2c5")
        );

        // Every digest is 64 lowercase hex after stripping.
        for a in &rel.assets {
            let d = a.sha256.as_deref().expect("fixture digests are all present");
            assert_eq!(d.len(), 64);
            assert!(d.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        }
    }

    /// The APK prefix must not swallow the setup exe or the extension zip —
    /// if it did, `resolve_asset` would see three matches and refuse.
    #[test]
    fn feed_parse_prefixes_are_disjoint() {
        let rel = parse_release(&load_response(LATEST)).unwrap();
        for (prefix, expect) in [
            (APK_ASSET_PREFIX, "RemoteControl-v1.5.0.apk"),
            (SETUP_ASSET_PREFIX, "RemoteControl-Setup-v1.5.0.exe"),
            (EXT_ASSET_PREFIX, "RemoteControl-Extension-v1.5.0.zip"),
        ] {
            let n = rel.assets.iter().filter(|a| a.name.starts_with(prefix)).count();
            assert_eq!(n, 1, "prefix {prefix} matched {n} assets");
            assert_eq!(resolve_asset(&rel, prefix).unwrap().name, expect);
        }
    }

    /// The `expectRefusal: "checksum"` contract from
    /// `12-releases-latest-null-digest.json`, executed rather than commented.
    #[test]
    fn feed_parse_null_digest_is_a_hard_checksum_refusal() {
        let rel = parse_release(&load_response(NULL_DIGEST)).expect("fixture parses");

        // The release itself is well-formed and the asset IS found — the
        // refusal is specifically about the absent digest, not about a
        // missing asset.
        assert!(
            rel.assets
                .iter()
                .any(|a| a.name.starts_with(SETUP_ASSET_PREFIX)),
            "the setup asset is present in the fixture"
        );

        let got = resolve_asset(&rel, SETUP_ASSET_PREFIX);
        assert_eq!(
            got.unwrap_err(),
            UpdateError::Checksum,
            "a null digest must be a hard refusal, never a skipped verification (D-15)"
        );
        // And the code that reaches the wire is the one the fixture names.
        assert_eq!(UpdateError::Checksum.code(), "checksum");

        // The two assets that DO carry digests still resolve — the refusal is
        // per-asset, not a whole-feed rejection.
        assert!(resolve_asset(&rel, APK_ASSET_PREFIX).is_ok());
        assert!(resolve_asset(&rel, EXT_ASSET_PREFIX).is_ok());
    }

    #[test]
    fn feed_parse_missing_asset_is_installer_not_network() {
        let rel = Release {
            version: "1.5.0".into(),
            assets: vec![],
        };
        assert_eq!(
            resolve_asset(&rel, SETUP_ASSET_PREFIX).unwrap_err(),
            UpdateError::Installer
        );
    }

    #[test]
    fn feed_parse_duplicate_asset_is_installer() {
        let dup = |name: &str| Asset {
            name: name.into(),
            url: "https://example.invalid/x".into(),
            size_bytes: 1,
            sha256: Some("a".repeat(64)),
        };
        let rel = Release {
            version: "1.5.0".into(),
            assets: vec![
                dup("RemoteControl-Setup-v1.5.0.exe"),
                dup("RemoteControl-Setup-v1.5.0.exe.bak"),
            ],
        };
        assert_eq!(
            resolve_asset(&rel, SETUP_ASSET_PREFIX).unwrap_err(),
            UpdateError::Installer
        );
    }

    #[test]
    fn strip_digest_accepts_only_64_hex_after_sha256() {
        let good = "sha256:74dcced8f351704c0e18c409cc63064ad5c72894e937f9915e3ab38c37027af1";
        assert_eq!(
            strip_digest(Some(good)).as_deref(),
            Some("74dcced8f351704c0e18c409cc63064ad5c72894e937f9915e3ab38c37027af1")
        );

        // Uppercase hex is accepted but normalised to lowercase, so the
        // comparison in verify_or_delete never depends on the API's casing.
        let upper = format!("sha256:{}", "AB".repeat(32));
        assert_eq!(strip_digest(Some(&upper)).as_deref(), Some("ab".repeat(32).as_str()));

        // null / absent
        assert_eq!(strip_digest(None), None);
        // wrong algorithm — a weaker hash is not a hash we accept
        assert_eq!(strip_digest(Some(&format!("sha1:{}", "a".repeat(40)))), None);
        assert_eq!(strip_digest(Some(&format!("md5:{}", "a".repeat(32)))), None);
        // no prefix at all
        assert_eq!(strip_digest(Some(&"a".repeat(64))), None);
        // wrong length, both directions
        assert_eq!(strip_digest(Some(&format!("sha256:{}", "a".repeat(63)))), None);
        assert_eq!(strip_digest(Some(&format!("sha256:{}", "a".repeat(65)))), None);
        // non-hex characters
        assert_eq!(strip_digest(Some(&format!("sha256:{}", "z".repeat(64)))), None);
        // empty
        assert_eq!(strip_digest(Some("")), None);
        assert_eq!(strip_digest(Some("sha256:")), None);
    }

    #[test]
    fn feed_parse_malformed_body_is_network() {
        assert_eq!(parse_release("not json").unwrap_err(), UpdateError::Network);
        assert_eq!(parse_release("{}").unwrap_err(), UpdateError::Network);
    }

    /// A release with no `assets` key at all parses (serde default) and then
    /// refuses at resolve time — it must not panic on the way.
    #[test]
    fn feed_parse_tolerates_absent_assets_array() {
        let rel = parse_release(r#"{"tag_name":"v1.5.0"}"#).expect("parses");
        assert_eq!(rel.version, "1.5.0");
        assert!(rel.assets.is_empty());
        assert_eq!(
            resolve_asset(&rel, SETUP_ASSET_PREFIX).unwrap_err(),
            UpdateError::Installer
        );
    }

    /// D-14, asserted as a string fact: the locator points at the release
    /// mirror and nowhere else. The full `owner/repo` literal is deliberately
    /// NOT repeated here — it must occur exactly once in this file, so that
    /// "where does the server download from" has a single answer to grep for.
    #[test]
    fn feed_locator_is_the_compiled_in_release_repo() {
        assert!(RELEASES_API.starts_with("https://api.github.com/repos/"));
        assert!(RELEASES_API.contains("remote-control-releases"));
        assert!(RELEASES_API.ends_with("/releases/latest"));
    }
}
