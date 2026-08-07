#!/usr/bin/env python3
from __future__ import annotations

import json
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from release_gate import (
    check_boot_matrix,
    check_git_clean,
    check_module_layout,
    check_permissions,
    check_signature,
)
from release_gate.common import GateError


def run(command: list[str], cwd: Path) -> None:
    subprocess.run(command, cwd=cwd, check=True, text=True, capture_output=True)


def add_zip(archive: zipfile.ZipFile, name: str, data: bytes, mode: int = 0o644) -> None:
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | mode) << 16
    archive.writestr(info, data)


def fake_aarch64_static_elf() -> bytes:
    data = bytearray(120)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<H", data, 16, 2)
    struct.pack_into("<H", data, 18, 183)
    struct.pack_into("<I", data, 20, 1)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<H", data, 52, 64)
    struct.pack_into("<H", data, 54, 56)
    struct.pack_into("<H", data, 56, 1)
    struct.pack_into("<I", data, 64, 1)
    return bytes(data)


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        for relative in check_module_layout.SOURCE_REQUIRED:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            content = "id=PatchNest\nversion=1.2.3\nversionCode=123\n" if relative == "module/module.prop" else "#!/system/bin/sh\nexit 0\n"
            target.write_text(content, encoding="utf-8")
        scripts = root / "scripts"
        scripts.mkdir(exist_ok=True)
        for name in ("verify_signing_key_policy.py", "verify_monocypher_pin.py"):
            (scripts / name).write_text("raise SystemExit(0)\n", encoding="utf-8")
        matrices = root / "device-matrix"
        matrices.mkdir(exist_ok=True)
        for source in (ROOT / "device-matrix").glob("*.yaml"):
            (matrices / source.name).write_bytes(source.read_bytes())
        (root / "version.properties").write_text(
            'kpm_signing_public_key="' + '1' * 64 + '"\n'
            'kpm_signing_key_fingerprint_sha256="' + '2' * 64 + '"\n'
            'kpm_signing_key_status="production"\n',
            encoding="utf-8",
        )
        run(["git", "init", "-q"], root)
        run(["git", "config", "user.email", "gate@example.invalid"], root)
        run(["git", "config", "user.name", "Gate Test"], root)
        run(["git", "add", "."], root)
        run(["git", "commit", "-qm", "fixture"], root)

    def candidate(self) -> Path:
        path = self.root / "candidate.zip"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
            for name in check_module_layout.CANDIDATE_REQUIRED:
                if name == "module.prop":
                    data = b"id=PatchNest\nversion=1.2.3\nversionCode=123\n"
                elif name == "bin/kpm-verify":
                    data = fake_aarch64_static_elf()
                else:
                    data = b"binary" if name.startswith("bin/") else b"content\n"
                add_zip(archive, name, data, 0o755 if name.startswith("bin/") else 0o644)
        digest = check_signature.sha256_file(path)
        path.with_name(path.name + ".sha256").write_text(f"{digest}  {path.name}\n", encoding="utf-8")
        provenance = {
            "schemaVersion": 2,
            "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip(),
            "sourceTreeStatus": "clean",
            "archive": path.name,
            "archiveSha256": digest,
            "archiveSize": path.stat().st_size,
            "kpmSigningPublicKey": "1" * 64,
            "kpmSigningKeyFingerprintSha256": "2" * 64,
            "kpmSigningKeyStatus": "production",
        }
        path.with_name("build-provenance.json").write_text(json.dumps(provenance), encoding="utf-8")
        return path

    def complete_matrices(
        self,
        *,
        same_device: bool = False,
        omit_runtime_digest: bool = False,
        reuse_digest: bool = False,
        one_manager: bool = False,
    ) -> str:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()
        matrix_dir = Path(tempfile.mkdtemp(prefix="patchnest-matrix-", dir=self.root.parent))
        for source in (self.root / "device-matrix").glob("*.yaml"):
            (matrix_dir / source.name).write_bytes(source.read_bytes())
        counter = 0
        for path in matrix_dir.glob("*.yaml"):
            data = json.loads(path.read_text(encoding="utf-8"))
            for case in data["cases"]:
                if not case["required"]:
                    case["status"] = "not-applicable"
                    continue
                counter += 1
                number = int(case["id"].split("-")[-1])
                is_ab = case["id"].startswith("AB-")
                manager = "apatch" if one_manager else ("magisk", "ksu-next", "apatch")[counter % 3]
                slot = "none" if case["id"].startswith("NA-") else ("a" if not is_ab or number % 2 else "b")
                record = {
                    "path": f"evidence/{case['id']}.tar.gz",
                    "sha256": "d" * 64 if reuse_digest else f"{counter:064x}",
                    "recordedAt": "2026-08-07T03:00:00Z",
                    "sessionId": f"session-{case['id'].lower()}",
                    "deviceAlias": "single-device" if same_device else ("device-1" if not is_ab or number % 2 else "device-2"),
                    "socFamily": "single-soc" if same_device else ("qcom-sm8750" if not is_ab or number % 2 else "qcom-sm8650"),
                    "rootManager": manager,
                    "activeSlot": "a" if same_device else slot,
                    "romFingerprintSha256": "b" * 64,
                    "kernelRelease": "6.6.89-android15",
                    "runtimeCompatSha256": "c" * 64,
                }
                if omit_runtime_digest:
                    record.pop("runtimeCompatSha256")
                case.update(status="pass", testedCommit=head, evidence=[record])
            path.write_text(json.dumps(data), encoding="utf-8")
        return head, matrix_dir


class ReleaseGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixture = Fixture(self.root)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_git_clean_and_dirty(self):
        self.assertEqual("pass", check_git_clean.check(self.root, expected_commit=None, release_ready=False)["status"])
        (self.root / "dirty.txt").write_text("dirty", encoding="utf-8")
        with self.assertRaises(GateError):
            check_git_clean.check(self.root, expected_commit=None, release_ready=False)

    def test_matrix_structure_and_release_block(self):
        self.assertEqual(47, check_boot_matrix.check(self.root, release_ready=False, expected_commit=None)["caseCount"])
        with self.assertRaises(GateError):
            check_boot_matrix.check(self.root, release_ready=True, expected_commit=None)

    def test_matrix_release_ready_evidence_binding(self):
        head, matrix_dir = self.fixture.complete_matrices()
        self.assertEqual(46, check_boot_matrix.check(self.root, release_ready=True, expected_commit=head, matrix_dir=matrix_dir)["counts"]["pass"])

    def test_matrix_rejects_insufficient_ab_coverage(self):
        head, matrix_dir = self.fixture.complete_matrices(same_device=True)
        with self.assertRaises(GateError):
            check_boot_matrix.check(self.root, release_ready=True, expected_commit=head, matrix_dir=matrix_dir)

    def test_matrix_rejects_missing_runtime_compat_digest(self):
        head, matrix_dir = self.fixture.complete_matrices(omit_runtime_digest=True)
        with self.assertRaises(GateError):
            check_boot_matrix.check(self.root, release_ready=True, expected_commit=head, matrix_dir=matrix_dir)

    def test_matrix_rejects_digest_reuse(self):
        head, matrix_dir = self.fixture.complete_matrices(reuse_digest=True)
        with self.assertRaises(GateError):
            check_boot_matrix.check(self.root, release_ready=True, expected_commit=head, matrix_dir=matrix_dir)

    def test_matrix_rejects_missing_root_manager_coverage(self):
        head, matrix_dir = self.fixture.complete_matrices(one_manager=True)
        with self.assertRaises(GateError):
            check_boot_matrix.check(self.root, release_ready=True, expected_commit=head, matrix_dir=matrix_dir)

    def test_candidate_layout_permissions_and_signature(self):
        candidate = self.fixture.candidate()
        self.assertEqual("pass", check_module_layout.check(self.root, candidate=candidate, release_ready=True)["status"])
        self.assertEqual("pass", check_permissions.check(self.root, candidate=candidate, release_ready=True)["status"])
        self.assertEqual("pass", check_signature.check(self.root, candidate=candidate, release_ready=True)["status"])

    def test_candidate_provenance_mismatch_is_rejected(self):
        candidate = self.fixture.candidate()
        provenance_path = candidate.with_name("build-provenance.json")
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        provenance["archiveSize"] += 1
        provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
        with self.assertRaises(GateError):
            check_signature.check(self.root, candidate=candidate, release_ready=True)

    def test_duplicate_candidate_path_is_rejected(self):
        candidate = self.root / "duplicate.zip"
        with zipfile.ZipFile(candidate, "w") as archive:
            add_zip(archive, "module.prop", b"id=PatchNest\nversion=1\nversionCode=1\n")
            add_zip(archive, "module.prop", b"duplicate")
        with self.assertRaises(GateError):
            check_module_layout.check(self.root, candidate=candidate, release_ready=False)

    def test_private_key_material_is_rejected(self):
        private = self.root / "private.txt"
        private.write_text("-----BEGIN " + "PRIVATE " + "KEY-----\nsecret\n", encoding="utf-8")
        run(["git", "add", "private.txt"], self.root)
        run(["git", "commit", "-qm", "bad key"], self.root)
        with self.assertRaises(GateError):
            check_signature.check(self.root, candidate=None, release_ready=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
