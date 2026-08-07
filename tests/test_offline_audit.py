#!/usr/bin/env python3
"""Self-tests for scripts/offline_audit.py using temporary repositories."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "patchnest_offline_audit", ROOT / "scripts/offline_audit.py"
)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)

SAFE_UTIL = r'''#!/system/bin/sh
find_boot_image() {
  BOOTIMAGE=$(find_block "boot$SLOT" boot boot_a boot_b)
}
image_stream_sha256() { sha256sum "$1" | awk '{print $1}'; }
verify_block_image_prefix() { return 0; }
flash_image() {
  blockdev --getsize64 "$2"
  blockdev --getro "$2"
  echo "Character-device boot flashing is not verified and is disabled"
  verify_block_image_prefix "$1" "$2" 1 4096
}
'''

SAFE_PATCH = r'''#!/system/bin/sh
validate_boot_image() { magiskboot unpack "$1"; }
STAMP=$(date +%Y%m%d%H%M%S)
backup_sha256="abc"
backup_verified=true
echo "Refusing to replace recovery backup with an already patched boot image"
validate_boot_image backup.img
'''

# Compatibility fixture for the legacy combined unpatch/restore implementation.
SAFE_UNPATCH = r'''#!/system/bin/sh
partition_name_for_target() { echo boot_a; }
backup_verified=true
backup_sha256="abc"
boot_image="boot_a"
rm -f kernel kernel.ori new-boot.img
'''

CURRENT_UNPATCH = r'''#!/system/bin/sh
require_flash_approval() { return 0; }
APPROVAL_MAX_AGE=120
validate_boot_image() { magiskboot unpack "$1"; }
patchnest_suspend_recovery_monitoring current-image-unpatched boot_a abc
rm -f kernel kernel.ori new-boot.img
echo "Current boot image unpatched and read back successfully"
'''

CURRENT_RESTORE = r'''#!/system/bin/sh
backup_verified=true
backup_sha256=abc
backup_file=boot_backup_1.img
partition_name_for_target() { echo boot_a; }
PATCHNEST_RESTORE_APPROVED=1
echo "No automatic backup selection was used"
echo "Validation complete; no block device was written"
patchnest_suspend_recovery_monitoring verified-backup-restored boot_a abc
echo "Verified backup restored and read back successfully"
'''

RECOVERY_STATE = r'''#!/system/bin/sh
current-image-unpatched
verified-backup-restored
patchnest_resume_recovery_monitoring() { return 0; }
echo '"monitoring_suspended": true'
'''


def write_fixture(
    root: Path,
    *,
    util: str = SAFE_UTIL,
    patch: str = SAFE_PATCH,
    unpatch: str = SAFE_UNPATCH,
) -> None:
    (root / "module/patch").mkdir(parents=True)
    (root / "webui").mkdir(parents=True)
    (root / "module/patch/util_functions.sh").write_text(util, encoding="utf-8")
    (root / "module/patch/boot_patch.sh").write_text(patch, encoding="utf-8")
    (root / "module/patch/boot_unpatch.sh").write_text(unpatch, encoding="utf-8")
    (root / "webui/constants.js").write_text(
        "export const escapeShell = value => JSON.stringify(String(value));\n",
        encoding="utf-8",
    )


def add_split_recovery_fixture(root: Path, *, unpatch: str = CURRENT_UNPATCH) -> None:
    (root / "module/patch/boot_unpatch.sh").write_text(unpatch, encoding="utf-8")
    (root / "module/patch/boot_restore_verified.sh").write_text(CURRENT_RESTORE, encoding="utf-8")
    (root / "module/patch/recovery_state.sh").write_text(RECOVERY_STATE, encoding="utf-8")
    (root / "module/post-fs-data.sh").write_text(
        "patchnest_recovery_monitoring_suspended\n", encoding="utf-8"
    )
    (root / "module/status.sh").write_text(
        "patchnest_resume_recovery_monitoring\n", encoding="utf-8"
    )


class OfflineAuditTests(unittest.TestCase):
    def run_checks(self, root: Path):
        findings = []
        AUDIT.check_boot_partition_selection(root, findings)
        AUDIT.check_flash_contract(root, findings)
        AUDIT.check_backup_contract(root, findings)
        AUDIT.check_shell_hazards(root, findings)
        AUDIT.check_webui_bridges(root, findings)
        return AUDIT.deduplicate(findings)

    def test_safe_legacy_fixture_has_no_blocker_or_error(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            findings = self.run_checks(root)
            severe = [item for item in findings if item.severity in {"blocker", "error"}]
            self.assertEqual([], severe)

    def test_safe_split_recovery_fixture_has_no_blocker_or_error(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            add_split_recovery_fixture(root)
            findings = self.run_checks(root)
            severe = [item for item in findings if item.severity in {"blocker", "error"}]
            self.assertEqual([], severe)

    def test_backup_logic_in_current_unpatch_is_blocker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            add_split_recovery_fixture(root, unpatch=CURRENT_UNPATCH + "\nbackup_verified=true\n")
            findings = self.run_checks(root)
            self.assertIn("UNPATCH-008", {item.check_id for item in findings})

    def test_vendor_boot_fallback_is_blocker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(
                root,
                util=SAFE_UTIL.replace(
                    'BOOTIMAGE=$(find_block "boot$SLOT" boot boot_a boot_b)',
                    'BOOTIMAGE=$(find_block "boot$SLOT" boot vendor_boot init_boot)',
                ),
            )
            findings = self.run_checks(root)
            self.assertIn("BOOT-003", {item.check_id for item in findings})

    def test_missing_readback_is_blocker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, util=SAFE_UTIL.replace("verify_block_image_prefix", "verify_prefix_removed"))
            findings = self.run_checks(root)
            self.assertIn("FLASH-001", {item.check_id for item in findings})

    def test_unquoted_rm_rf_is_error(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, patch=SAFE_PATCH + "rm -rf $UNTRUSTED_PATH\n")
            findings = self.run_checks(root)
            self.assertIn("SHELL-002", {item.check_id for item in findings})

    def test_dynamic_html_sink_is_error(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            (root / "webui/view.js").write_text(
                "target.innerHTML = `<b>${remoteName}</b>`;\n", encoding="utf-8"
            )
            findings = self.run_checks(root)
            self.assertIn("WEBUI-001", {item.check_id for item in findings})

    def test_unescaped_privileged_exec_is_warning(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            (root / "webui/bridge.js").write_text(
                "exec(`cat ${userPath}`);\n", encoding="utf-8"
            )
            findings = self.run_checks(root)
            matching = [item for item in findings if item.check_id == "WEBUI-002"]
            self.assertEqual(1, len(matching))
            self.assertEqual("warning", matching[0].severity)

    def test_report_render_and_json_schema(self):
        finding = AUDIT.Finding(
            severity="warning",
            check_id="TEST-001",
            path="fixture.sh",
            line=4,
            message="test finding",
            evidence="echo `value`",
        )
        report = AUDIT.render_markdown(ROOT, [finding])
        self.assertIn("TEST-001", report)
        self.assertIn("fixture.sh:4", report)
        payload = {"schemaVersion": 1, "findings": [finding.as_dict()]}
        encoded = json.dumps(payload)
        self.assertEqual(1, json.loads(encoded)["schemaVersion"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
