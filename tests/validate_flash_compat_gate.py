#!/usr/bin/env python3
"""Static ordering contracts for the pre-write runtime compatibility gate."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUARD = (ROOT / "module/patch/flash_guard.sh").read_text(encoding="utf-8")
RUNNER = (ROOT / "scripts/run_offline_checks.sh").read_text(encoding="utf-8")

required = {
    "runtime_compatibility_gate()": "compatibility gate function is missing",
    "runtime_compat_check.sh": "gate does not invoke the packaged probe",
    "--strict": "gate does not require strict compatibility",
    "Runtime compatibility gate failed; no block write was attempted": "gate failure is not explicit",
    "return 8": "gate failure has no distinct error code",
}
for token, message in required.items():
    if token not in GUARD:
        raise AssertionError(message)

gate_call = GUARD.find("runtime_compatibility_gate ||")
setrw = GUARD.find('blockdev --setrw "$_target"')
dd_write = GUARD.find('dd if="$_raw_source" of="$_target"')
if gate_call < 0 or setrw < 0 or dd_write < 0:
    raise AssertionError("flash write sequence cannot be located")
if not (gate_call < setrw < dd_write):
    raise AssertionError("compatibility gate does not run before setrw and dd")

for path in ("tests/test_flash_compat_gate.sh", "tests/validate_flash_compat_gate.py"):
    if path not in RUNNER:
        raise AssertionError(f"{path} is not included in the offline runner")

print("Flash runtime compatibility gate contracts validated.")
