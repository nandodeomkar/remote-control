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


CHECKS = [
    check_fixture_dir_exists,
    check_nine_wire_fixtures,
    check_wire_fixture_schema,
    check_apply_payload_has_only_target,
    check_pct_belongs_to_downloading_only,
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
