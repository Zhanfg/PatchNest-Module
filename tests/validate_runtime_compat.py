#!/usr/bin/env python3
"""Static contracts for runtime compatibility and read-only device evidence."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE = (ROOT / "module/runtime_compat_check.sh").read_text(encoding="utf-8")
CUSTOMIZE = (ROOT / "module/customize.sh").read_text(encoding="utf-8")
COLLECTOR = (ROOT / "scripts/collect_device_evidence.sh").read_text(encoding="utf-8")
RUNNER = (ROOT / "scripts/run_offline_checks.sh").read_text(encoding="utf-8")

required = {
    "mktemp -d": "mktemp template probe missing",
    "unzip -Z1": "unzip -Z1 probe missing",
    "du -sk": "du -sk probe missing",
    "sha256sum -c": "sha256sum -c probe missing",
    "kpm_verify__require_backend": "packaged Ed25519 backend probe missing",
    "ed25519_verifier": "packaged verifier result row missing",
    "iflag=fullblock": "dd iflag probe missing",
    "conv=notrunc,fsync": "dd conv probe missing",
    "blockdev --getsize64": "blockdev size probe missing",
    "blockdev --getbsz": "blockdev block-size probe missing",
    "blockdev --getro": "blockdev read-only probe missing",
    "required options are advertised; --setrw was not executed": "setrw non-execution boundary missing",
    "find_kernel_boot_image": "boot target discovery probe missing",
    "partition_name_for_target": "partition mapping probe missing",
    "--strict": "strict mode missing",
    "required_failures": "required failure summary missing",
}
for token, message in required.items():
    if token not in PROBE:
        raise AssertionError(message)

if "kpm_verify__require_openssl" in PROBE:
    raise AssertionError("Android compatibility still depends on system OpenSSL")
if re.search(r"(?m)^\s*blockdev\s+--setrw(?:\s|$)", PROBE):
    raise AssertionError("runtime compatibility probe executes blockdev --setrw")
if re.search(r"(?m)^\s*dd\s+[^\n]*\bof=[^\n]*(?:/dev/block|BOOTIMAGE|\$_target)", PROBE):
    raise AssertionError("runtime compatibility probe can write a block target")
for package_path in ("runtime_compat_check.sh", "bin/kpm-verify", "bin/kp-safemode"):
    if package_path not in CUSTOMIZE:
        raise AssertionError(f"installer package validation omits {package_path}")

collector_required = {
    "schema_version=2": "device evidence schema was not advanced",
    "runtime_compat_check.sh": "collector does not invoke the compatibility probe",
    "--strict": "collector does not capture the strict compatibility result",
    "runtime-compat-console.txt": "collector omits compatibility output",
    "runtime-compat-status.txt": "collector omits compatibility exit status",
    "PATCHNEST_STATE_DIR=\"$COMPAT_STATE\"": "probe state is not isolated inside evidence output",
    "The runtime probe did not execute blockdev --setrw.": "sharing notice omits the no-setrw boundary",
}
for token, message in collector_required.items():
    if token not in COLLECTOR:
        raise AssertionError(message)

write_command = re.search(r"(?ms)^write_command\(\)\s*\{(?P<body>.*?)^\}", COLLECTOR)
if not write_command:
    raise AssertionError("collector write_command function is missing")
body = write_command.group("body")
if not re.search(r"(?m)^\s*\($", body) or not re.search(r"(?m)^\s*\)\s*>\"\$OUTPUT_DIR/\$_name\"", body):
    raise AssertionError("collector diagnostic commands are not isolated in a subshell")
if re.search(r"(?m)^\s*blockdev\s+--setrw(?:\s|$)", COLLECTOR):
    raise AssertionError("device evidence collector executes blockdev --setrw")
if re.search(r"(?m)^\s*dd\s+[^\n]*\bof=[^\n]*(?:/dev/block|BOOT_BLOCK)", COLLECTOR):
    raise AssertionError("device evidence collector can write a block target")

for test_path in (
    "tests/test_runtime_compat_host.sh",
    "tests/test_device_evidence_host.sh",
    "tests/validate_runtime_compat.py",
):
    if test_path not in RUNNER:
        raise AssertionError(f"{test_path} is not in the offline runner")

print("Runtime compatibility and device evidence contracts validated.")
