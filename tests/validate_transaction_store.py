#!/usr/bin/env python3
"""Static contracts for the shared KPM transaction store."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "module/kpm_transaction_store.sh").read_text(encoding="utf-8")
VECTORS = (ROOT / "tests/test_kpm_transaction_store.sh").read_text(encoding="utf-8")


def require(text: str, token: str, message: str) -> None:
    if token not in text:
        raise AssertionError(message)


def reject(text: str, token: str, message: str) -> None:
    if token in text:
        raise AssertionError(message)


def main() -> int:
    for token, message in (
        ("patchnest_store_kpm_transaction", "transaction API is missing"),
        ("patchnest_valid_transaction_root", "destination roots are not constrained"),
        ("patchnest_valid_transaction_reason", "transaction reasons are not constrained"),
        ("patchnest_rollback_transaction", "transaction rollback routine is missing"),
        ("patchnest_mark_rollback_failed", "failed rollback evidence is not retained"),
        ("state=rollback-failed", "failed rollback state is not explicit"),
        ("transaction rollback incomplete; preserved entry", "rollback preservation is not observable"),
        ('[ ! -L "$PATCHNEST_STATE_DIR" ]', "state root symlinks are accepted"),
        ('[ ! -L "$_pt_destination_root" ]', "transaction root symlinks are accepted"),
        ("command -v sha256sum", "transaction integrity dependency is not required"),
        ("checksums.sha256", "transaction checksum set is missing"),
        ("manifest.properties", "transaction manifest is missing"),
        ("state=complete", "successful transaction is never finalized"),
    ):
        require(STORE, token, message)

    reject(STORE, "eval ", "transaction store evaluates metadata")
    reject(STORE, "source ", "transaction store executes transaction metadata")

    for token, message in (
        ("KPM transaction store vectors passed", "focused test has no success sentinel"),
        ("checksum failure unexpectedly succeeded", "checksum-failure rollback is not tested"),
        ("state=rollback-failed", "rollback-conflict preservation is not tested"),
        ("symlink transaction root unexpectedly accepted", "symlink-root rejection is not tested"),
        ('"$SYSTEM_SHA256SUM" -c checksums.sha256', "successful transaction integrity is not tested"),
    ):
        require(VECTORS, token, message)

    print("KPM transaction store contracts validated.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
