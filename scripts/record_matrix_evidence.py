#!/usr/bin/env python3
"""Record one physical-test result in an external PatchNest matrix.

Preview-only by default. `--write` atomically updates exactly one external
matrix file. This command never reads a device and never writes a block device.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

FILES = ("ab_device.yaml", "non_ab_device.yaml", "avb_cases.yaml", "recovery_cases.yaml")
CASE_RE = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{2}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9_.+-]{1,96}$")
ROOT_MANAGERS = {"magisk", "ksu", "ksu-next", "apatch", "none", "recovery"}
SLOTS = {"a", "b", "none", "unknown"}


def die(message: str) -> None:
    raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def regular(path: str, label: str) -> Path:
    raw = Path(path).expanduser()
    if raw.is_symlink():
        die(f"{label} must not be a symlink: {raw}")
    resolved = raw.resolve()
    if not resolved.is_file() or resolved.stat().st_size == 0:
        die(f"{label} is missing or empty: {resolved}")
    return resolved


def git_head(root: Path) -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, check=True,
        text=True, capture_output=True,
    ).stdout.strip()


def candidate_binding(root: Path, candidate_arg: str) -> tuple[str, str]:
    candidate = regular(candidate_arg, "candidate")
    digest_file = regular(str(candidate.with_name(candidate.name + ".sha256")), "candidate digest")
    provenance_file = regular(str(candidate.with_name("build-provenance.json")), "candidate provenance")
    digest = sha256(candidate)
    if digest_file.read_text(encoding="utf-8").splitlines() != [f"{digest}  {candidate.name}"]:
        die("candidate digest file does not exactly bind the selected archive")
    provenance = json.loads(provenance_file.read_text(encoding="utf-8"))
    expected = {
        "schemaVersion": 2,
        "sourceCommit": git_head(root),
        "sourceTreeStatus": "clean",
        "archive": candidate.name,
        "archiveSha256": digest,
        "archiveSize": candidate.stat().st_size,
    }
    for key, value in expected.items():
        if provenance.get(key) != value:
            die(f"candidate provenance {key} mismatch")
    return expected["sourceCommit"], digest


def external_matrix_dir(root: Path, value: str) -> Path:
    raw = Path(value).expanduser()
    if raw.is_symlink():
        die("matrix directory must not be a symlink")
    resolved = raw.resolve()
    if not resolved.is_dir():
        die("matrix directory is missing")
    try:
        resolved.relative_to(root)
    except ValueError:
        return resolved
    die("completed matrix directory must be outside the Git work tree")


def find_case(directory: Path, case_id: str) -> tuple[Path, dict, dict]:
    found: list[tuple[Path, dict, dict]] = []
    for name in FILES:
        path = directory / name
        if path.is_symlink() or not path.is_file():
            die(f"matrix file is missing or unsafe: {path}")
        document = json.loads(path.read_text(encoding="utf-8"))
        for case in document.get("cases", []):
            if case.get("id") == case_id:
                found.append((path, document, case))
    if len(found) != 1:
        die(f"case {case_id} must occur exactly once; found {len(found)}")
    return found[0]


def safe_label(value: str, label: str) -> str:
    if not LABEL_RE.fullmatch(value):
        die(f"{label} contains unsafe characters")
    return value


def relative_evidence_label(value: str) -> str:
    path = PurePosixPath(value)
    if not value or value.startswith("/") or "\\" in value or ".." in path.parts:
        die("evidence label must be a safe relative POSIX path")
    return value


def timestamp(value: str | None) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    if value is None:
        return now.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        die("recorded-at must include a timezone")
    if parsed.astimezone(dt.timezone.utc) > now + dt.timedelta(minutes=5):
        die("recorded-at is more than five minutes in the future")
    return value


def atomic_write(path: Path, content: str) -> None:
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    try:
        with temp.open("x", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, path.stat().st_mode & 0o777)
        os.replace(temp, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temp.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix-dir", required=True)
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--evidence-archive", required=True)
    parser.add_argument("--evidence-label", required=True)
    parser.add_argument("--runtime-compat-report", required=True)
    parser.add_argument("--rom-fingerprint-file", required=True)
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--device-alias", required=True)
    parser.add_argument("--soc-family", required=True)
    parser.add_argument("--root-manager", required=True)
    parser.add_argument("--active-slot", required=True)
    parser.add_argument("--kernel-release", required=True)
    parser.add_argument("--recorded-at")
    parser.add_argument("--expected-commit")
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    try:
        root = Path(__file__).resolve().parents[1]
        if not CASE_RE.fullmatch(args.case_id):
            die("invalid case id")
        commit, candidate_sha = candidate_binding(root, args.candidate)
        if args.expected_commit and args.expected_commit != commit:
            die("candidate sourceCommit does not match --expected-commit")
        directory = external_matrix_dir(root, args.matrix_dir)
        path, document, case = find_case(directory, args.case_id)
        if case.get("status") == "pass" and not args.replace:
            die("case already passes; use --replace to replace its evidence")
        if case.get("status") == "not-applicable":
            die("cannot record evidence for a not-applicable case")
        if args.root_manager not in ROOT_MANAGERS:
            die("unsupported root manager")
        if args.active_slot not in SLOTS:
            die("unsupported active slot")
        if args.case_id.startswith("AB-") and args.active_slot not in {"a", "b"}:
            die("A/B case requires slot a or b")
        if args.case_id.startswith("NA-") and args.active_slot != "none":
            die("non-A/B case requires active-slot none")

        evidence = regular(args.evidence_archive, "evidence archive")
        runtime = regular(args.runtime_compat_report, "runtime compatibility report")
        fingerprint = regular(args.rom_fingerprint_file, "ROM fingerprint file")
        record = {
            "path": relative_evidence_label(args.evidence_label),
            "sha256": sha256(evidence),
            "recordedAt": timestamp(args.recorded_at),
            "sessionId": safe_label(args.session_id, "session-id"),
            "deviceAlias": safe_label(args.device_alias, "device-alias"),
            "socFamily": safe_label(args.soc_family, "soc-family"),
            "rootManager": args.root_manager,
            "activeSlot": args.active_slot,
            "romFingerprintSha256": sha256(fingerprint),
            "kernelRelease": args.kernel_release.strip(),
            "runtimeCompatSha256": sha256(runtime),
            "candidateSha256": candidate_sha,
        }
        if not record["kernelRelease"] or len(record["kernelRelease"]) > 160:
            die("kernel-release is missing or too long")
        case.update(status="pass", testedCommit=commit, evidence=[record])
        rendered = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
        if args.write:
            atomic_write(path, rendered)
        print(json.dumps({"matrix": str(path), "caseId": args.case_id, "write": args.write, "testedCommit": commit, "evidence": record}, indent=2, sort_keys=True))
        if not args.write:
            print("Preview only; rerun with --write to update the external matrix.")
        return 0
    except (ValueError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
