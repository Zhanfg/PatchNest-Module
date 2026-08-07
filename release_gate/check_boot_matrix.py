#!/usr/bin/env python3
"""Validate structured device evidence matrices and release-ready completion."""
from __future__ import annotations

import argparse
import datetime as dt
import re
from pathlib import Path
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from release_gate.common import GateError, emit, git_head, load_yaml12_json, root_path

EXPECTED_FILES = (
    "ab_device.yaml",
    "non_ab_device.yaml",
    "avb_cases.yaml",
    "recovery_cases.yaml",
)
ALLOWED_STATUS = {"pending", "pass", "fail", "blocked", "not-applicable"}
ALLOWED_SLOTS = {"a", "b", "none", "unknown"}
ALLOWED_ROOT_MANAGERS = {"magisk", "ksu", "ksu-next", "apatch", "none", "recovery"}
REQUIRED_ROOT_MANAGERS = {"magisk", "ksu-next", "apatch"}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
CASE_ID_RE = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{2}$")
SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9_.+-]{1,96}$")


def _valid_timestamp(value: str) -> bool:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.tzinfo is not None
    except (TypeError, ValueError):
        return False


def _validate_coverage(filename: str, document: dict, evidence_records: list[dict]) -> None:
    coverage = document.get("minimumCoverage")
    if coverage is None:
        return
    if not isinstance(coverage, dict):
        raise GateError(f"{filename}: minimumCoverage must be an object")

    devices = {record["deviceAlias"] for record in evidence_records}
    socs = {record["socFamily"] for record in evidence_records}
    slots = {record["activeSlot"] for record in evidence_records}

    required_devices = coverage.get("devices", 0)
    required_socs = coverage.get("socFamilies", 0)
    required_slots = coverage.get("requiredSlots", [])
    if not isinstance(required_devices, int) or required_devices < 0:
        raise GateError(f"{filename}: minimumCoverage.devices must be a non-negative integer")
    if not isinstance(required_socs, int) or required_socs < 0:
        raise GateError(f"{filename}: minimumCoverage.socFamilies must be a non-negative integer")
    if not isinstance(required_slots, list) or any(slot not in ALLOWED_SLOTS for slot in required_slots):
        raise GateError(f"{filename}: minimumCoverage.requiredSlots is invalid")
    if len(devices) < required_devices:
        raise GateError(f"{filename}: device coverage {len(devices)} < required {required_devices}")
    if len(socs) < required_socs:
        raise GateError(f"{filename}: SoC coverage {len(socs)} < required {required_socs}")
    missing_slots = sorted(set(required_slots) - slots)
    if missing_slots:
        raise GateError(f"{filename}: missing active-slot coverage: {', '.join(missing_slots)}")


def _validate_evidence(case_id: str, record: dict) -> None:
    required_strings = (
        "path",
        "sessionId",
        "deviceAlias",
        "socFamily",
        "kernelRelease",
    )
    for key in required_strings:
        value = record.get(key)
        if not isinstance(value, str) or not value:
            raise GateError(f"{case_id}: evidence {key} missing")
    for key in ("sessionId", "deviceAlias", "socFamily"):
        if not SAFE_LABEL_RE.fullmatch(record[key]):
            raise GateError(f"{case_id}: evidence {key} contains unsafe characters")
    if not SHA256_RE.fullmatch(str(record.get("sha256", ""))):
        raise GateError(f"{case_id}: evidence sha256 invalid")
    if not SHA256_RE.fullmatch(str(record.get("romFingerprintSha256", ""))):
        raise GateError(f"{case_id}: ROM fingerprint digest invalid")
    if not SHA256_RE.fullmatch(str(record.get("runtimeCompatSha256", ""))):
        raise GateError(f"{case_id}: runtime compatibility digest invalid")
    if not _valid_timestamp(record.get("recordedAt", "")):
        raise GateError(f"{case_id}: evidence recordedAt invalid or lacks timezone")
    if record.get("rootManager") not in ALLOWED_ROOT_MANAGERS:
        raise GateError(f"{case_id}: unsupported rootManager")
    if record.get("activeSlot") not in ALLOWED_SLOTS:
        raise GateError(f"{case_id}: unsupported activeSlot")


def check(
    root: Path,
    *,
    release_ready: bool,
    expected_commit: str | None,
    matrix_dir: Path | None = None,
) -> dict:
    matrix_dir = (matrix_dir or (root / "device-matrix")).expanduser().resolve()
    if not matrix_dir.is_dir() or matrix_dir.is_symlink():
        raise GateError(f"matrix directory is missing or unsafe: {matrix_dir}")
    if release_ready:
        try:
            matrix_dir.relative_to(root)
        except ValueError:
            pass
        else:
            raise GateError("release-ready matrices must be outside the Git work tree")
    missing = [name for name in EXPECTED_FILES if not (matrix_dir / name).is_file()]
    if missing:
        raise GateError("missing matrix files: " + ", ".join(missing))

    head = expected_commit or (git_head(root) if (root / ".git").exists() else None)
    seen: set[str] = set()
    evidence_digests: dict[str, tuple[str, ...]] = {}
    global_evidence: list[dict] = []
    counts = {status: 0 for status in ALLOWED_STATUS}
    total = 0
    for filename in EXPECTED_FILES:
        path = matrix_dir / filename
        document = load_yaml12_json(path)
        if document.get("schemaVersion") != 1:
            raise GateError(f"{filename}: schemaVersion must be 1")
        if not isinstance(document.get("matrix"), str) or not document["matrix"]:
            raise GateError(f"{filename}: matrix name is missing")
        cases = document.get("cases")
        if not isinstance(cases, list) or not cases:
            raise GateError(f"{filename}: cases must be a non-empty array")
        matrix_evidence: list[dict] = []
        for case in cases:
            total += 1
            if not isinstance(case, dict):
                raise GateError(f"{filename}: each case must be an object")
            case_id = case.get("id")
            if not isinstance(case_id, str) or not CASE_ID_RE.fullmatch(case_id):
                raise GateError(f"{filename}: invalid case id {case_id!r}")
            if case_id in seen:
                raise GateError(f"duplicate case id: {case_id}")
            seen.add(case_id)
            title = case.get("title")
            if not isinstance(title, str) or not title.strip():
                raise GateError(f"{case_id}: title is missing")
            if not isinstance(case.get("required"), bool):
                raise GateError(f"{case_id}: required must be boolean")
            status = case.get("status")
            if status not in ALLOWED_STATUS:
                raise GateError(f"{case_id}: invalid status {status!r}")
            counts[status] += 1
            tested_commit = case.get("testedCommit", "")
            evidence = case.get("evidence", [])
            if not isinstance(evidence, list):
                raise GateError(f"{case_id}: evidence must be an array")
            if status == "not-applicable" and case["required"]:
                raise GateError(f"{case_id}: required case cannot be not-applicable")
            if status == "pass":
                if not isinstance(tested_commit, str) or not COMMIT_RE.fullmatch(tested_commit):
                    raise GateError(f"{case_id}: passing case lacks full testedCommit")
                if head and tested_commit != head:
                    raise GateError(f"{case_id}: testedCommit {tested_commit} does not match {head}")
                if not evidence:
                    raise GateError(f"{case_id}: passing case has no evidence")
                for record in evidence:
                    if not isinstance(record, dict):
                        raise GateError(f"{case_id}: evidence record must be an object")
                    _validate_evidence(case_id, record)
                    evidence_identity = (
                        record["path"], record["sessionId"], record["deviceAlias"],
                        record["socFamily"], record["rootManager"], record["activeSlot"],
                        record["romFingerprintSha256"], record["kernelRelease"],
                        record["runtimeCompatSha256"], record["recordedAt"],
                    )
                    previous_identity = evidence_digests.get(record["sha256"])
                    if previous_identity and previous_identity != evidence_identity:
                        raise GateError(f"{case_id}: evidence digest is reused with conflicting metadata")
                    evidence_digests[record["sha256"]] = evidence_identity
                    matrix_evidence.append(record)
                    global_evidence.append(record)
            elif tested_commit or evidence:
                raise GateError(f"{case_id}: non-pass case must not claim tested commit/evidence")
            if release_ready and case["required"] and status != "pass":
                raise GateError(f"release blocker {case_id} is {status}, expected pass")
        if release_ready:
            if filename == "ab_device.yaml" and any(record["activeSlot"] not in {"a", "b"} for record in matrix_evidence):
                raise GateError("ab_device.yaml: every passing evidence record must identify slot a or b")
            if filename == "non_ab_device.yaml" and any(record["activeSlot"] != "none" for record in matrix_evidence):
                raise GateError("non_ab_device.yaml: every passing evidence record must use activeSlot=none")
            _validate_coverage(filename, document, matrix_evidence)

    if release_ready:
        covered_managers = {record["rootManager"] for record in global_evidence}
        missing_managers = sorted(REQUIRED_ROOT_MANAGERS - covered_managers)
        if missing_managers:
            raise GateError("missing root-manager coverage: " + ", ".join(missing_managers))

    return {
        "gate": "boot-matrix",
        "status": "pass",
        "releaseReady": release_ready,
        "caseCount": total,
        "counts": counts,
        "summary": f"Device matrix structure valid ({total} cases)",
        "details": [f"{key}={counts[key]}" for key in sorted(counts)],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--expected-commit")
    parser.add_argument("--matrix-dir")
    parser.add_argument("--release-ready", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        matrix_dir = Path(args.matrix_dir) if args.matrix_dir else None
        emit(
            check(
                root_path(args.root),
                release_ready=args.release_ready,
                expected_commit=args.expected_commit,
                matrix_dir=matrix_dir,
            ),
            as_json=args.json,
        )
        return 0
    except GateError as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
