#!/usr/bin/env python3
"""Ensure imported KPM source is never compiled as root on-device."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPILER = (ROOT / "module/compile_kpm.sh").read_text(encoding="utf-8")
INSTALLER = (ROOT / "module/install_kpm.sh").read_text(encoding="utf-8")

required_compiler = [
    "On-device KPM source compilation is disabled",
    "Build the module off-device using a pinned KernelPatch SDK and toolchain",
    "exit 1",
]
for token in required_compiler:
    if token not in COMPILER:
        print(f"ERROR: compile policy missing: {token}", file=sys.stderr)
        raise SystemExit(1)

for forbidden in (
    "command -v tcc",
    "command -v clang",
    "command -v gcc",
    "$COMPILER -c",
    "cat > \"$KPM_INCLUDE/kpmodule.h\"",
):
    if forbidden in COMPILER:
        print(f"ERROR: on-device compilation behavior returned: {forbidden}", file=sys.stderr)
        raise SystemExit(1)

required_installer = [
    "SRC_COUNT=$(find",
    "On-device KPM source compilation is disabled; provide one prebuilt .kpm",
    '"$SRC_COUNT" = "0"',
    "ZIP must contain exactly one prebuilt KPM binary",
]
for token in required_installer:
    if token not in INSTALLER:
        print(f"ERROR: installer source-rejection contract missing: {token}", file=sys.stderr)
        raise SystemExit(1)

for forbidden in (
    '"$MODDIR/compile_kpm.sh" "$TMPDIR/root"',
    "Source KPM compilation failed",
    "Compiled KPM failed kptools validation",
):
    if forbidden in INSTALLER:
        print(f"ERROR: installer still invokes on-device source compilation: {forbidden}", file=sys.stderr)
        raise SystemExit(1)

print("Off-device-only KPM source build policy validated.")
