#!/usr/bin/env python3
"""Unit tests for scripts/verify_signing_key_policy.py."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "patchnest_signing_key_policy", ROOT / "scripts/verify_signing_key_policy.py"
)
assert SPEC and SPEC.loader
POLICY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = POLICY
SPEC.loader.exec_module(POLICY)

PUBLIC_KEY = "a6cee3371d164daf9ad2ed38ecaf1d492e7867fc6df31f810e69eaa0dd45259b"
PROBE_SIGNATURE = (
    "886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e"
    "32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703"
)
FINGERPRINT = hashlib.sha256(bytes.fromhex(PUBLIC_KEY)).hexdigest()


def write_fixture(
    root: Path,
    *,
    public_key: str = PUBLIC_KEY,
    probe_signature: str = PROBE_SIGNATURE,
    fingerprint: str = FINGERPRINT,
    status: str = "development",
    source_key: str = PUBLIC_KEY,
    source_probe_signature: str = PROBE_SIGNATURE,
    build_key: str = PUBLIC_KEY,
    build_probe_signature: str = PROBE_SIGNATURE,
) -> None:
    (root / "module").mkdir(parents=True)
    (root / "version.properties").write_text(
        "\n".join(
            [
                f'kpm_signing_public_key="{public_key}"',
                f'kpm_signing_probe_signature="{probe_signature}"',
                f'kpm_signing_key_fingerprint_sha256="{fingerprint}"',
                f'kpm_signing_key_status="{status}"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    (root / "module/kpm_verify.sh").write_text(
        "\n".join(
            [
                f'KPM_SIGN_PUBKEY_HEX="{source_key}"',
                f'KPM_VERIFY_PROBE_SIG="{source_probe_signature}"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    (root / "build.sh").write_text(
        "\n".join(
            [
                f"PROBE_PUBLIC_KEY={build_key}",
                f"PROBE_SIGNATURE={build_probe_signature}",
                "",
            ]
        ),
        encoding="utf-8",
    )


class SigningKeyPolicyTests(unittest.TestCase):
    def test_repository_consistency_passes(self):
        self.assertEqual([], POLICY.verify(ROOT))

    def test_development_key_is_not_release_ready(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            self.assertEqual([], POLICY.verify(root))
            errors = POLICY.verify(root, release_ready=True)
            self.assertTrue(any("requires kpm_signing_key_status=production" in error for error in errors))

    def test_production_key_is_release_ready(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, status="production")
            self.assertEqual([], POLICY.verify(root, release_ready=True))

    def test_source_key_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, source_key="00" * 32)
            self.assertTrue(any("module/kpm_verify.sh public key" in error for error in POLICY.verify(root)))

    def test_build_key_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, build_key="00" * 32)
            self.assertTrue(any("build.sh probe public key" in error for error in POLICY.verify(root)))

    def test_source_probe_signature_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, source_probe_signature="00" * 64)
            self.assertTrue(any("module/kpm_verify.sh probe signature" in error for error in POLICY.verify(root)))

    def test_build_probe_signature_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, build_probe_signature="00" * 64)
            self.assertTrue(any("build.sh probe signature" in error for error in POLICY.verify(root)))

    def test_invalid_probe_signature_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, probe_signature="bad")
            self.assertTrue(any("probe_signature" in error for error in POLICY.verify(root)))

    def test_fingerprint_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, fingerprint="00" * 32)
            self.assertTrue(any("fingerprint mismatch" in error for error in POLICY.verify(root)))

    def test_duplicate_source_literals_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            shell_path = root / "module/kpm_verify.sh"
            shell_path.write_text(shell_path.read_text(encoding="utf-8") * 2, encoding="utf-8")
            build_path = root / "build.sh"
            build_path.write_text(build_path.read_text(encoding="utf-8") * 2, encoding="utf-8")
            errors = POLICY.verify(root)
            for name in (
                "KPM_SIGN_PUBKEY_HEX",
                "KPM_VERIFY_PROBE_SIG",
                "PROBE_PUBLIC_KEY",
                "PROBE_SIGNATURE",
            ):
                self.assertTrue(any(f"exactly one literal {name}" in error for error in errors))

    def test_invalid_status_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, status="unknown")
            self.assertTrue(any("development or production" in error for error in POLICY.verify(root)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
