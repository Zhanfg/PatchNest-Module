#!/usr/bin/env python3
"""Require every passing external matrix record to bind the selected candidate."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

FILES = ("ab_device.yaml", "non_ab_device.yaml", "avb_cases.yaml", "recovery_cases.yaml")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fail(message: str) -> None:
    raise ValueError(message)


def check(root: Path, matrix_dir: Path, candidate: Path) -> dict:
    raw_matrix = matrix_dir.expanduser()
    raw_candidate = candidate.expanduser()
    if raw_matrix.is_symlink() or raw_candidate.is_symlink():
        fail("matrix directory and candidate must not be symlinks")
    matrix_dir = raw_matrix.resolve()
    candidate = raw_candidate.resolve()
    if not matrix_dir.is_dir() or not candidate.is_file():
        fail("matrix directory or candidate is missing")
    try:
        matrix_dir.relative_to(root.resolve())
    except ValueError:
        pass
    else:
        fail("completed matrix directory must be outside the Git work tree")

    candidate_sha = sha256(candidate)
    passing = 0
    for name in FILES:
        path = matrix_dir / name
        if path.is_symlink() or not path.is_file():
            fail(f"matrix file is missing or unsafe: {path}")
        document = json.loads(path.read_text(encoding="utf-8"))
        for case in document.get("cases", []):
            if case.get("status") != "pass":
                continue
            evidence = case.get("evidence")
            if not isinstance(evidence, list) or not evidence:
                fail(f"{case.get('id')}: passing case has no evidence")
            for record in evidence:
                if not isinstance(record, dict) or record.get("candidateSha256") != candidate_sha:
                    fail(f"{case.get('id')}: evidence is not bound to candidate {candidate_sha}")
                passing += 1
    if passing == 0:
        fail("external matrices contain no passing evidence")
    return {"status": "pass", "candidateSha256": candidate_sha, "passingEvidenceRecords": passing}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--matrix-dir", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = check(Path(args.root), Path(args.matrix_dir), Path(args.candidate))
        print(json.dumps(result, indent=2, sort_keys=True) if args.json else f"PASS: {result['passingEvidenceRecords']} evidence records bind {result['candidateSha256']}")
        return 0
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
