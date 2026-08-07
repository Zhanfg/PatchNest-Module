#!/usr/bin/env python3
"""Verify PatchNest KPM signing-key provenance and release policy."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX128 = re.compile(r"^[0-9a-f]{128}$")
SHELL_KEY = re.compile(r'^KPM_SIGN_PUBKEY_HEX="([0-9a-f]{64})"$', re.MULTILINE)
SHELL_PROBE_SIGNATURE = re.compile(
    r'^KPM_VERIFY_PROBE_SIG="([0-9a-f]{128})"$', re.MULTILINE
)
BUILD_KEY = re.compile(r"^PROBE_PUBLIC_KEY=([0-9a-f]{64})$", re.MULTILINE)
BUILD_PROBE_SIGNATURE = re.compile(r"^PROBE_SIGNATURE=([0-9a-f]{128})$", re.MULTILINE)
ALLOWED_STATUS = {"development", "production"}


def parse_kv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if not key:
            raise ValueError(f"{path}:{number}: empty key")
        if key in values:
            raise ValueError(f"{path}:{number}: duplicate key {key}")
        values[key] = value
    return values


def one_literal(pattern: re.Pattern[str], source: str, name: str, errors: list[str]) -> str:
    matches = pattern.findall(source)
    if len(matches) != 1:
        errors.append(f"source must define exactly one literal {name}")
        return ""
    return matches[0]


def verify(root: Path, *, release_ready: bool = False) -> list[str]:
    errors: list[str] = []
    versions = parse_kv(root / "version.properties")
    verifier = (root / "module/kpm_verify.sh").read_text(encoding="utf-8")
    build = (root / "build.sh").read_text(encoding="utf-8")

    configured_key = versions.get("kpm_signing_public_key", "")
    configured_probe = versions.get("kpm_signing_probe_signature", "")
    configured_fingerprint = versions.get("kpm_signing_key_fingerprint_sha256", "")
    status = versions.get("kpm_signing_key_status", "")

    if not HEX64.fullmatch(configured_key):
        errors.append("kpm_signing_public_key must be exactly 32 bytes of lowercase hex")
    if not HEX128.fullmatch(configured_probe):
        errors.append("kpm_signing_probe_signature must be exactly 64 bytes of lowercase hex")
    if not HEX64.fullmatch(configured_fingerprint):
        errors.append("kpm_signing_key_fingerprint_sha256 must be 64 lowercase hex characters")
    if status not in ALLOWED_STATUS:
        errors.append("kpm_signing_key_status must be development or production")

    source_key = one_literal(SHELL_KEY, verifier, "KPM_SIGN_PUBKEY_HEX", errors)
    source_probe = one_literal(
        SHELL_PROBE_SIGNATURE, verifier, "KPM_VERIFY_PROBE_SIG", errors
    )
    build_key = one_literal(BUILD_KEY, build, "PROBE_PUBLIC_KEY", errors)
    build_probe = one_literal(BUILD_PROBE_SIGNATURE, build, "PROBE_SIGNATURE", errors)

    for location, actual in (
        ("module/kpm_verify.sh public key", source_key),
        ("build.sh probe public key", build_key),
    ):
        if configured_key and actual and configured_key != actual:
            errors.append(f"version.properties public key does not match {location}")

    for location, actual in (
        ("module/kpm_verify.sh probe signature", source_probe),
        ("build.sh probe signature", build_probe),
    ):
        if configured_probe and actual and configured_probe != actual:
            errors.append(f"version.properties probe signature does not match {location}")

    if HEX64.fullmatch(configured_key):
        actual_fingerprint = hashlib.sha256(bytes.fromhex(configured_key)).hexdigest()
        if configured_fingerprint != actual_fingerprint:
            errors.append(
                "KPM signing public-key fingerprint mismatch: "
                f"expected {configured_fingerprint or '<missing>'}, got {actual_fingerprint}"
            )

    if release_ready and status != "production":
        errors.append(
            "release readiness requires kpm_signing_key_status=production; "
            "the current development key is restricted to non-published testing"
        )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument(
        "--release-ready",
        action="store_true",
        help="require a production signing key suitable for a published release",
    )
    args = parser.parse_args()

    try:
        errors = verify(Path(args.root).resolve(), release_ready=args.release_ready)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    mode = "release-ready" if args.release_ready else "consistency"
    print(f"KPM signing-key {mode} policy verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
