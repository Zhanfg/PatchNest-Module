#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("record_matrix_evidence", ROOT / "scripts/record_matrix_evidence.py")
assert SPEC and SPEC.loader
REC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REC)


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_atomic_write_replaces_file_and_leaves_no_temp(self):
        target = self.root / "matrix.yaml"
        target.write_text("old\n", encoding="utf-8")
        REC.atomic_write(target, "new\n")
        self.assertEqual("new\n", target.read_text(encoding="utf-8"))
        self.assertEqual([], list(self.root.glob(".matrix.yaml.tmp.*")))

    def test_regular_rejects_symlink(self):
        actual = self.root / "actual"
        actual.write_text("data", encoding="utf-8")
        link = self.root / "link"
        link.symlink_to(actual)
        with self.assertRaises(ValueError):
            REC.regular(str(link), "fixture")

    def test_future_timestamp_is_rejected(self):
        future = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)).isoformat()
        with self.assertRaises(ValueError):
            REC.timestamp(future)

    def test_relative_evidence_label_rejects_traversal(self):
        with self.assertRaises(ValueError):
            REC.relative_evidence_label("../evidence.tar.gz")

    def test_find_case_requires_unique_case(self):
        for name in REC.FILES:
            document = {"schemaVersion": 1, "matrix": name, "cases": []}
            if name == REC.FILES[0]:
                document["cases"].append({"id": "AB-01"})
            (self.root / name).write_text(json.dumps(document), encoding="utf-8")
        path, _, case = REC.find_case(self.root, "AB-01")
        self.assertEqual(REC.FILES[0], path.name)
        self.assertEqual("AB-01", case["id"])

    def test_candidate_binding_checks_digest_and_provenance(self):
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.root, check=True)
        (self.root / "tracked").write_text("x", encoding="utf-8")
        subprocess.run(["git", "add", "tracked"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=self.root, check=True)
        head = REC.git_head(self.root)
        candidate = self.root / "candidate.zip"
        candidate.write_bytes(b"candidate")
        digest = REC.sha256(candidate)
        candidate.with_name(candidate.name + ".sha256").write_text(f"{digest}  {candidate.name}\n", encoding="utf-8")
        candidate.with_name("build-provenance.json").write_text(json.dumps({
            "schemaVersion": 2,
            "sourceCommit": head,
            "sourceTreeStatus": "clean",
            "archive": candidate.name,
            "archiveSha256": digest,
            "archiveSize": candidate.stat().st_size,
        }), encoding="utf-8")
        self.assertEqual((head, digest), REC.candidate_binding(self.root, str(candidate)))
        candidate.with_name(candidate.name + ".sha256").write_text("0" * 64 + f"  {candidate.name}\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            REC.candidate_binding(self.root, str(candidate))


if __name__ == "__main__":
    unittest.main(verbosity=2)
