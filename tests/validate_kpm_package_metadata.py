#!/usr/bin/env python3
"""Static contracts for KPM ZIP metadata and signature disambiguation."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "module/install_kpm.sh").read_text(encoding="utf-8")


def require(token: str, message: str) -> None:
    if token not in INSTALLER:
        raise AssertionError(message)


def main() -> int:
    require("get_unique_prop", "unique property reader is missing")
    require("OPTIONAL_PROP_VALUE", "optional property result is not returned in the parent shell")
    require("read_optional_prop", "optional property reader is missing")
    require("load_optional_prop", "parent-shell optional property gate is missing")
    require("module.prop contains duplicate key", "duplicate optional metadata is not fatal")
    require("module.prop contains duplicate key: id", "duplicate required id is not fatal")

    expected = {
        "name": "MOD_NAME",
        "version": "MOD_VERSION",
        "event": "MOD_EVENT",
        "args": "MOD_ARGS",
        "autoLoad": "MOD_AUTOLOAD",
    }
    for key, variable in expected.items():
        gate = f'load_optional_prop "$PROP_FILE" {key}'
        assignment = f"{variable}=$OPTIONAL_PROP_VALUE"
        require(gate, f"{key} is not validated in the parent shell")
        require(assignment, f"{key} does not use the validated parent-shell value")
        if INSTALLER.index(gate) > INSTALLER.index(assignment):
            raise AssertionError(f"{key} is assigned before duplicate validation")

    if re.search(r"MOD_(?:NAME|VERSION|EVENT|ARGS|AUTOLOAD)=\$\(read_optional_prop", INSTALLER):
        raise AssertionError("optional property failure can still be swallowed by command substitution")

    require('_signature_count=0', "signature candidate count is not initialized")
    require('for _signature_candidate in "${KPM_FILE}.sig" "${KPM_FILE%.kpm}.sig"', "known signature forms are not enumerated")
    require('ZIP contains multiple signature files for the KPM', "ambiguous signatures are not rejected")
    if INSTALLER.index("_signature_count=0") > INSTALLER.index("verify_kpm_sig"):
        raise AssertionError("signature ambiguity is checked after cryptographic verification")

    print("KPM package metadata contracts validated.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
