//! The version comparator (protoVersion 1.8, phase 12, D-26).
//!
//! WHAT IT OWNS: parsing an `X.Y.Z` release tag into a `(major, minor, patch)`
//! tuple, and answering "how does `a` compare to `b`" with one of four values.
//! It is the Rust half of a CROSS-LANGUAGE contract: the phone's Dart
//! comparator loads the SAME `protocol/fixtures/update/10-version-compare.json`
//! truth table and must agree case-for-case. A disagreement does not show up as
//! a test failure — it shows up in the field as a phone offering an update the
//! server then refuses as `stale`.
//!
//! WHY IT EXISTS NOW: the comparator is the one piece of update logic that is
//! pure. Every other part of the feature needs the network, the filesystem or
//! a Windows API; this needs nothing, so it lives in `server-core` where the
//! ZERO-WINDOWS-DEPENDENCIES invariant holds and CI Linux can test it. It
//! depends on nothing outside `core`.
//!
//! FAILURE POSTURE — **UNKNOWN IS NEVER NEWER.** Anything that is not exactly
//! three non-negative integers fails to parse, and an unparseable version on
//! EITHER side makes the whole comparison [`VersionOrder::Unknown`]. An unknown
//! must never trigger an update offer: a malformed tag, a blank string, a
//! `latest` alias or an overflowing component are all "we cannot tell", and
//! "we cannot tell" is not "there is something newer".
//!
//! THE LEXICAL TRAP the tuple compare exists to avoid: `"1.10.0" < "1.9.0"` as
//! strings, and `1.10 < 1.9` as floats. Only an explicit integer tuple compare
//! gets `1.10.0` vs `1.9.0` right.
//!
//! PRE-RELEASE CONSEQUENCE, deliberate and not accidental: `X.Y.Z-rcN` does not
//! parse, so it compares as `unknown` and a pre-release is NEVER offered to a
//! client. GitHub's `/releases/latest` already excludes pre-releases, so this is
//! the second belt rather than the primary mechanism.

/// How one version compares to another (D-26). The four variants match the
/// `expect` values in `protocol/fixtures/update/10-version-compare.json`
/// verbatim.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VersionOrder {
    /// `a` is strictly greater than `b` — the only value that may lead to an
    /// update offer.
    Newer,
    /// `a` is strictly less than `b`.
    Older,
    /// `a` and `b` are the same release.
    Same,
    /// At least one side FAILED TO PARSE. Never treat this as [`Self::Newer`].
    Unknown,
}

impl VersionOrder {
    /// The fixture's wire spelling of this variant — the exact string the
    /// shared truth table uses.
    pub fn as_str(&self) -> &'static str {
        match self {
            VersionOrder::Newer => "newer",
            VersionOrder::Older => "older",
            VersionOrder::Same => "same",
            VersionOrder::Unknown => "unknown",
        }
    }
}

/// Parse a release tag into `(major, minor, patch)`, or `None` if it is not
/// EXACTLY three non-negative integers.
///
/// A single leading `v` is stripped first, because git tags are published as
/// `vX.Y.Z` while package versions are bare — `v1.4.0` and `1.4.0` are the same
/// release.
///
/// Returns `None` — deliberately, in every one of these cases:
/// - fewer or more than three dot-separated components (`1.4`, `1.4.0.1`);
/// - any component that is not a non-empty run of ASCII digits, which is what
///   rejects `1.4.0-rc1`, `latest`, `1.x.0`, `+1.4.0` and the empty string;
/// - any component that OVERFLOWS `u64`. Overflow must NOT saturate: a
///   saturated `u64::MAX` would compare as newer than everything and hand a
///   garbage tag the power to trigger an update offer.
pub fn parse_semver(s: &str) -> Option<(u64, u64, u64)> {
    let s = s.strip_prefix('v').unwrap_or(s);

    let mut parts = s.split('.');
    let major = parse_component(parts.next()?)?;
    let minor = parse_component(parts.next()?)?;
    let patch = parse_component(parts.next()?)?;
    // A fourth component means this is not X.Y.Z — refuse rather than ignore.
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}

/// One `X`, `Y` or `Z` component: a non-empty run of ASCII digits that fits a
/// `u64`.
///
/// The explicit digit check is NOT redundant with `u64::from_str`: that parser
/// accepts a leading `+` (`"+4".parse::<u64>()` is `Ok(4)`), which would let
/// `1.+4.0` through as `1.4.0`. A release tag never has a sign.
fn parse_component(part: &str) -> Option<u64> {
    if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    // Overflow yields Err, which becomes None — never a saturated value.
    part.parse::<u64>().ok()
}

/// How does `a` compare to `b` (D-26)?
///
/// [`VersionOrder::Unknown`] whenever EITHER side fails [`parse_semver`] — the
/// asymmetric alternative (treating an unparseable `b` as "older than
/// anything") would make a corrupt installed-version string offer every update
/// on the feed.
pub fn compare_versions(a: &str, b: &str) -> VersionOrder {
    let (Some(a), Some(b)) = (parse_semver(a), parse_semver(b)) else {
        return VersionOrder::Unknown;
    };
    // Tuple compare, NOT string and NOT float: (1, 10, 0) > (1, 9, 0).
    match a.cmp(&b) {
        std::cmp::Ordering::Greater => VersionOrder::Newer,
        std::cmp::Ordering::Less => VersionOrder::Older,
        std::cmp::Ordering::Equal => VersionOrder::Same,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_plain_triple_and_strips_a_leading_v() {
        assert_eq!(parse_semver("1.4.0"), Some((1, 4, 0)));
        assert_eq!(parse_semver("v1.4.0"), Some((1, 4, 0)));
        assert_eq!(parse_semver("0.0.0"), Some((0, 0, 0)));
    }

    #[test]
    fn refuses_everything_that_is_not_exactly_three_integers() {
        for bad in [
            "",            // blank
            "v",           // just the prefix
            "1.4",         // two components — never coerced to 1.4.0
            "1.4.0.1",     // four components
            "1.4.0-rc1",   // pre-release: never offered (D-20/D-26)
            "latest",      // alias
            "1.x.0",       // non-numeric component
            "1..0",        // empty component
            "1.+4.0",      // signed component — u64::from_str would accept "+4"
            " 1.4.0",      // whitespace
            "999999999999999999999.0.0", // overflows u64 — must NOT saturate
        ] {
            assert_eq!(parse_semver(bad), None, "{bad:?} must not parse");
        }
    }

    #[test]
    fn unknown_is_never_newer_on_either_side() {
        // The whole safety property in one test: a garbage version can never
        // produce an offer, whichever side it lands on.
        assert_eq!(compare_versions("latest", "1.4.0"), VersionOrder::Unknown);
        assert_eq!(compare_versions("1.4.0", "latest"), VersionOrder::Unknown);
        assert_eq!(compare_versions("", ""), VersionOrder::Unknown);
    }

    #[test]
    fn the_lexical_trap_compares_by_integer_tuple() {
        assert_eq!(compare_versions("1.10.0", "1.9.0"), VersionOrder::Newer);
        assert_eq!(compare_versions("1.9.0", "1.10.0"), VersionOrder::Older);
        assert_eq!(compare_versions("2.0.0", "1.99.99"), VersionOrder::Newer);
        assert_eq!(compare_versions("v1.4.0", "1.4.0"), VersionOrder::Same);
    }

    #[test]
    fn as_str_matches_the_fixture_vocabulary() {
        assert_eq!(VersionOrder::Newer.as_str(), "newer");
        assert_eq!(VersionOrder::Older.as_str(), "older");
        assert_eq!(VersionOrder::Same.as_str(), "same");
        assert_eq!(VersionOrder::Unknown.as_str(), "unknown");
    }
}
