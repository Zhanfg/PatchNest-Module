#!/usr/bin/env python3
"""Static contracts for quarantine and failed-transaction visibility."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "module/manage_kpm_quarantine.sh").read_text(encoding="utf-8")


def require(token: str, message: str) -> None:
    if token not in MANAGER:
        raise AssertionError(message)


def reject(token: str, message: str) -> None:
    if token in MANAGER:
        raise AssertionError(message)


def main() -> int:
    for token, message in (
        ('QUARANTINE_DIR="$PNDIR/kpm_quarantine"', "quarantine root is missing"),
        ('FAILED_DIR="$PNDIR/kpm_failed"', "failed transaction root is missing"),
        ("scope_root", "scope-to-root resolver is missing"),
        ('quarantine) printf \'%s\' "$QUARANTINE_DIR"', "quarantine scope is not explicit"),
        ('failed) printf \'%s\' "$FAILED_DIR"', "failed scope is not explicit"),
        ("list [quarantine|failed|all]", "CLI help omits scoped listing"),
        ("inspect <quarantine|failed> <entry-id>", "CLI help omits scoped inspection"),
        ("scope\\tentry_id", "list output does not identify transaction scope"),
        ("list_scope quarantine", "all-scope listing omits quarantine"),
        ("list_scope failed", "all-scope listing omits failures"),
        ("inspect_scope_entry", "scoped inspection is missing"),
        ("scope=$_scope", "inspection output does not identify scope"),
        ("failed transactions cannot be activated", "failed activation boundary is undocumented"),
        ('_original=$(resolve_entry "$QUARANTINE_DIR" "$1")', "activation is not hard-bound to quarantine"),
        ("Invalid or incomplete quarantine transaction", "activation does not report its quarantine-only boundary"),
    ):
        require(token, message)

    # Backward-compatible defaults remain quarantine-only.
    require("1) list_entries quarantine", "plain list no longer defaults to quarantine")
    require("2) inspect_scope_entry quarantine \"$2\"", "plain inspect no longer defaults to quarantine")

    # The activation call must not contain caller-selected root/scope data.
    activation = re.search(r"(?ms)^activate_entry\(\)\s*\{(?P<body>.*?)^\}", MANAGER)
    if not activation:
        raise AssertionError("activate_entry function is missing")
    body = activation.group("body")
    if "FAILED_DIR" in body or "scope_root" in body or "$_scope" in body:
        raise AssertionError("activation can be redirected to the failed transaction scope")
    if 'resolve_entry "$QUARANTINE_DIR" "$1"' not in body:
        raise AssertionError("activation does not resolve directly from quarantine")

    reject("--force", "force activation exists")
    reject("eval ", "manager evaluates transaction metadata")
    if re.search(r"(?m)^\s*delete\)", MANAGER):
        raise AssertionError("manager exposes a destructive delete command")
    if re.search(r"(?m)^\s*activate-failed\)", MANAGER):
        raise AssertionError("manager exposes failed-transaction activation")

    print("Transaction visibility contracts validated.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
