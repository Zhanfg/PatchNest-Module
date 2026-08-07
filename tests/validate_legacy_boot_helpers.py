#!/usr/bin/env python3
"""Prevent reactivation of legacy broad boot and flash helpers."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET_PATH = ROOT / "module/patch/boot_target.sh"
TARGET = TARGET_PATH.read_text(encoding="utf-8")
RUNNER = (ROOT / "scripts/run_offline_checks.sh").read_text(encoding="utf-8")

if not re.search(
    r"(?ms)^find_boot_image\(\)\s*\{\s*find_kernel_boot_image\s*\}",
    TARGET,
):
    raise AssertionError("legacy find_boot_image is not overridden by boot-only discovery")

override = re.search(r"(?ms)^find_boot_image\(\)\s*\{(?P<body>.*?)^\}", TARGET)
assert override is not None
if re.search(r"vendor_boot|init_boot|find_block", override.group("body")):
    raise AssertionError("legacy public boot resolver reintroduced broad partition discovery")

for path in sorted((ROOT / "module").rglob("*.sh")):
    relative = path.relative_to(ROOT).as_posix()
    text = path.read_text(encoding="utf-8", errors="replace")

    if relative not in {
        "module/patch/util_functions.sh",
        "module/patch/boot_target.sh",
    } and re.search(r"\bfind_boot_image\b", text):
        raise AssertionError(f"{relative} calls the legacy boot resolver directly")

    if relative in {
        "module/patch/util_functions.sh",
        "module/patch/flash_guard.sh",
    }:
        continue
    if not re.search(r"\bflash_image\b", text):
        continue
    if '. "$MODPATH/flash_guard.sh"' not in text:
        raise AssertionError(f"{relative} uses flash_image without loading flash_guard.sh")

if "tests/validate_legacy_boot_helpers.py" not in RUNNER:
    raise AssertionError("legacy helper contracts are not included in the offline runner")

print("Legacy boot and flash helper contracts validated.")
