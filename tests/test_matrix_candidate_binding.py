#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("matrix_binding", ROOT / "release_gate/check_matrix_candidate_binding.py")
assert SPEC and SPEC.loader
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class MatrixBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        self.matrix = self.base / "matrices"
        self.matrix.mkdir()
        self.candidate = self.base / "candidate.zip"
        self.candidate.write_bytes(b"candidate")
        self.digest = MOD.sha256(self.candidate)
        for index, name in enumerate(MOD.FILES):
            cases = [{
                "id": f"T-{index:02d}",
                "status": "pass",
                "evidence": [{"candidateSha256": self.digest}],
            }]
            (self.matrix / name).write_text(json.dumps({"cases": cases}), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def test_matching_candidate_passes(self):
        result = MOD.check(self.root, self.matrix, self.candidate)
        self.assertEqual(4, result["passingEvidenceRecords"])

    def test_mismatched_candidate_fails(self):
        path = self.matrix / MOD.FILES[0]
        document = json.loads(path.read_text(encoding="utf-8"))
        document["cases"][0]["evidence"][0]["candidateSha256"] = "0" * 64
        path.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaises(ValueError):
            MOD.check(self.root, self.matrix, self.candidate)

    def test_internal_matrix_fails(self):
        internal = self.root / "matrices"
        internal.mkdir()
        for source in self.matrix.iterdir():
            (internal / source.name).write_bytes(source.read_bytes())
        with self.assertRaises(ValueError):
            MOD.check(self.root, internal, self.candidate)


if __name__ == "__main__":
    unittest.main(verbosity=2)
