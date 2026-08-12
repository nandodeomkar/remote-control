#!/usr/bin/env python3
"""Validate the protocol/fixtures/update/ family (phase 12, protoVersion 1.8).

Standalone: no third-party imports, no network. Resolves the fixture directory
from this file's own location, so it may be run from any working directory.

Prints OK and exits 0 when every check passes; prints the first failing
assertion and exits 1 otherwise.

Structure note: each check is a named function taking no arguments and
returning either None (pass) or a failure string (fail). CHECKS is the
ordered list main() walks; further checks are appended to that same list.
"""

import json
import os
import re
import sys

# Repo-root-relative resolution from this file's own location, so the script is
# immune to the caller's cwd (the same discipline the Rust fixture loader uses
# with CARGO_MANIFEST_DIR).
_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
FIXTURE_DIR = os.path.join(_REPO_ROOT, "protocol", "fixtures", "update")

WIRE_FIXTURE_RE = re.compile(r"^0[1-9]-.*\.json$")
REQUIRED_KEYS = ("name", "description", "wire", "expect")


def _load(filename):
    """Read one fixture. Returns (data, None) or (None, failure-string)."""
    path = os.path.join(FIXTURE_DIR, filename)
    if not os.path.isfile(path):
        return None, "missing fixture: protocol/fixtures/update/%s" % filename
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle), None
    except ValueError as exc:
        return None, "protocol/fixtures/update/%s is not valid JSON: %s" % (filename, exc)


def _wire_fixture_names():
    if not os.path.isdir(FIXTURE_DIR):
        return []
    return sorted(n for n in os.listdir(FIXTURE_DIR) if WIRE_FIXTURE_RE.match(n))


def check_fixture_dir_exists():
    if not os.path.isdir(FIXTURE_DIR):
        return "fixture directory not found: %s" % FIXTURE_DIR
    return None


def check_nine_wire_fixtures():
    """Exactly nine files match 0[1-9]-*.json."""
    names = _wire_fixture_names()
    if len(names) != 9:
        return "expected exactly 9 files matching 0[1-9]-*.json in protocol/fixtures/update/, found %d: %s" % (
            len(names),
            ", ".join(names) or "(none)",
        )
    return None


def check_wire_fixture_schema():
    """Every wire fixture parses as JSON and carries name/description/wire/expect."""
    for name in _wire_fixture_names():
        data, failure = _load(name)
        if failure:
            return failure
        if not isinstance(data, dict):
            return "%s: top level must be a JSON object" % name
        for key in REQUIRED_KEYS:
            if key not in data:
                return "%s: missing required fixture key %r (schema is %s)" % (
                    name,
                    key,
                    "/".join(REQUIRED_KEYS),
                )
    return None


def check_apply_payload_has_only_target():
    """D-14 structural check: update.apply carries `target` and nothing else."""
    data, failure = _load("04-update-apply.json")
    if failure:
        return failure
    payload = data.get("wire", {}).get("p")
    if not isinstance(payload, dict):
        return "04-update-apply.json: wire.p must be a JSON object"
    keys = sorted(payload.keys())
    if keys != ["target"]:
        return (
            "04-update-apply.json: D-14 violation - wire.p must hold exactly one key, `target`, "
            "found %s. The server resolves the asset URL and its sha256 itself; no locator may "
            "ever cross the wire." % (keys or "(no keys)")
        )
    return None


def check_pct_belongs_to_downloading_only():
    """D-10 check: `pct` accompanies stage `downloading` and no other stage."""
    expectations = [
        ("05-update-progress-downloading.json", True),
        ("06-update-progress-failed-checksum.json", False),
        ("07-update-progress-uptodate.json", False),
    ]
    for name, should_have_pct in expectations:
        data, failure = _load(name)
        if failure:
            return failure
        payload = data.get("wire", {}).get("p")
        if not isinstance(payload, dict):
            return "%s: wire.p must be a JSON object" % name
        has_pct = "pct" in payload
        if has_pct != should_have_pct:
            return "%s: D-10 violation - stage %r %s carry `pct` (pct accompanies `downloading` only)" % (
                name,
                payload.get("stage"),
                "must" if should_have_pct else "must not",
            )
    return None


def check_version_compare_table():
    """10-version-compare.json holds a non-empty case table incl. the lexical trap."""
    data, failure = _load("10-version-compare.json")
    if failure:
        return failure
    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        return "10-version-compare.json: `cases` must be a non-empty array"
    allowed = {"newer", "older", "same", "unknown"}
    for index, case in enumerate(cases):
        if not isinstance(case, dict):
            return "10-version-compare.json: cases[%d] must be an object" % index
        for key in ("a", "b", "expect"):
            if key not in case:
                return "10-version-compare.json: cases[%d] missing key %r" % (index, key)
        if case["expect"] not in allowed:
            return "10-version-compare.json: cases[%d] expect=%r is outside the closed set %s" % (
                index,
                case["expect"],
                sorted(allowed),
            )
    trap = [c for c in cases if c["a"] == "1.10.0" and c["b"] == "1.9.0"]
    if not trap:
        return (
            "10-version-compare.json: the lexical-trap case (a=1.10.0, b=1.9.0) is missing - "
            "it is the whole reason this table exists"
        )
    if trap[0]["expect"] != "newer":
        return "10-version-compare.json: 1.10.0 vs 1.9.0 must expect `newer`, found %r" % trap[0]["expect"]
    return None


def check_releases_latest_digests():
    """11-releases-latest.json holds exactly three assets, each with a sha256 digest."""
    data, failure = _load("11-releases-latest.json")
    if failure:
        return failure
    assets = data.get("response", {}).get("assets")
    if not isinstance(assets, list):
        return "11-releases-latest.json: response.assets must be an array"
    if len(assets) != 3:
        return "11-releases-latest.json: expected exactly 3 assets (apk, setup exe, extension zip), found %d" % len(
            assets
        )
    digest_re = re.compile(r"^sha256:[0-9a-f]{64}$")
    for asset in assets:
        name = asset.get("name", "(unnamed)")
        for key in ("name", "browser_download_url", "size", "state", "digest"):
            if key not in asset:
                return "11-releases-latest.json: asset %s is missing the %r field" % (name, key)
        digest = asset.get("digest")
        if not isinstance(digest, str) or not digest_re.match(digest):
            return "11-releases-latest.json: asset %s has digest %r - expected sha256: + 64 lowercase hex" % (
                name,
                digest,
            )
    return None


def check_null_digest_is_a_hard_refusal():
    """12-releases-latest-null-digest.json pins D-15: a null digest refuses with `checksum`."""
    data, failure = _load("12-releases-latest-null-digest.json")
    if failure:
        return failure
    assets = data.get("response", {}).get("assets")
    if not isinstance(assets, list):
        return "12-releases-latest-null-digest.json: response.assets must be an array"
    if not any(asset.get("digest") is None for asset in assets):
        return (
            "12-releases-latest-null-digest.json: no asset carries a null digest - the fixture "
            "cannot prove the D-15 hard-refusal rule without one"
        )
    refusal = data.get("expectRefusal")
    if refusal != "checksum":
        return (
            "12-releases-latest-null-digest.json: expectRefusal must be \"checksum\" (a missing "
            "digest is a HARD refusal, never a skipped verification - D-15), found %r" % refusal
        )
    return None


CHECKS = [
    check_fixture_dir_exists,
    check_nine_wire_fixtures,
    check_wire_fixture_schema,
    check_apply_payload_has_only_target,
    check_pct_belongs_to_downloading_only,
    check_version_compare_table,
    check_releases_latest_digests,
    check_null_digest_is_a_hard_refusal,
]


def main():
    for check in CHECKS:
        failure = check()
        if failure:
            sys.stderr.write("FAIL [%s]: %s\n" % (check.__name__, failure))
            return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
