#!/usr/bin/env python3
"""Verify signing policy, verifier provenance, and candidate signature layout."""
from __future__ import annotations

import argparse
import json
import re
import struct
import zipfile
from pathlib import Path, PurePosixPath
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from release_gate.common import GateError, emit, git_head, root_path, run, sha256_file

PRIVATE_KEY_MARKERS = tuple(
    ("-----BEGIN " + label + "PRIVATE " + "KEY-----").encode("ascii")
    for label in ("", "RSA ", "EC ", "OPENSSH ")
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PRIVATE_NAME_RE = re.compile(r"(^|/)(id_rsa|id_ed25519|.*\.(?:p12|pfx|jks|keystore|key|pem))$", re.I)
CANDIDATE_REQUIRED = (
    "bin/kpm-verify",
    "kpm_verify.sh",
    "licenses/Monocypher-LICENCE.md",
)


def _tracked_files(root: Path) -> list[Path]:
    output = run(["git", "ls-files", "-z"], cwd=root).stdout
    return [root / item for item in output.split("\0") if item]


def _scan_private_material(root: Path) -> None:
    findings: list[str] = []
    for path in _tracked_files(root):
        relative = path.relative_to(root).as_posix()
        if PRIVATE_NAME_RE.search(relative):
            findings.append(relative)
            continue
        try:
            if path.stat().st_size <= 1024 * 1024:
                data = path.read_bytes()
                if any(marker in data for marker in PRIVATE_KEY_MARKERS):
                    findings.append(relative)
        except OSError:
            findings.append(relative + " (unreadable)")
    if findings:
        raise GateError("tracked private-key material detected: " + ", ".join(findings[:20]))


def _safe_zip_name(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not name.startswith("/") and "\\" not in name and ".." not in path.parts


def _check_static_aarch64_elf(data: bytes) -> None:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise GateError("candidate bin/kpm-verify is not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise GateError("candidate verifier must be ELF64 little-endian")
    machine = struct.unpack_from("<H", data, 18)[0]
    if machine != 183:
        raise GateError(f"candidate verifier machine is {machine}, expected AArch64 (183)")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize = struct.unpack_from("<H", data, 54)[0]
    phnum = struct.unpack_from("<H", data, 56)[0]
    if phentsize < 56 or phnum > 512 or phoff + phentsize * phnum > len(data):
        raise GateError("candidate verifier has invalid program headers")
    for index in range(phnum):
        p_type = struct.unpack_from("<I", data, phoff + index * phentsize)[0]
        if p_type == 3:
            raise GateError("candidate verifier contains PT_INTERP and is not static")




def _read_version_properties(root: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    path = root / "version.properties"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise GateError(f"cannot read {path}: {exc}") from exc
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in values:
            raise GateError(f"duplicate version.properties key: {key}")
        values[key] = value.strip().strip('"')
    return values


def _check_candidate_provenance(root: Path, candidate: Path) -> list[str]:
    digest_path = candidate.with_name(candidate.name + ".sha256")
    provenance_path = candidate.with_name("build-provenance.json")
    if not digest_path.is_file():
        raise GateError(f"candidate digest file not found: {digest_path}")
    if not provenance_path.is_file():
        raise GateError(f"candidate provenance file not found: {provenance_path}")

    actual_sha = sha256_file(candidate)
    digest_lines = digest_path.read_text(encoding="utf-8").splitlines()
    expected_line = f"{actual_sha}  {candidate.name}"
    if digest_lines != [expected_line]:
        raise GateError("candidate digest file is not an exact single-line archive binding")

    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GateError(f"invalid build provenance: {exc}") from exc
    if not isinstance(provenance, dict) or provenance.get("schemaVersion") != 2:
        raise GateError("build provenance schemaVersion must be 2")

    expected = {
        "sourceCommit": git_head(root),
        "sourceTreeStatus": "clean",
        "archive": candidate.name,
        "archiveSha256": actual_sha,
        "archiveSize": candidate.stat().st_size,
    }
    for key, value in expected.items():
        if provenance.get(key) != value:
            raise GateError(f"build provenance {key} mismatch")

    properties = _read_version_properties(root)
    key_pairs = {
        "kpmSigningPublicKey": "kpm_signing_public_key",
        "kpmSigningKeyFingerprintSha256": "kpm_signing_key_fingerprint_sha256",
        "kpmSigningKeyStatus": "kpm_signing_key_status",
    }
    for provenance_key, property_key in key_pairs.items():
        value = properties.get(property_key)
        if not value or provenance.get(provenance_key) != value:
            raise GateError(f"build provenance {provenance_key} does not match version.properties")
    if provenance.get("kpmSigningKeyStatus") != "production":
        raise GateError("release-ready provenance must use a production signing key")
    if not SHA256_RE.fullmatch(str(provenance.get("kpmSigningKeyFingerprintSha256", ""))):
        raise GateError("release-ready signing-key fingerprint is invalid")

    return [
        f"candidateSha256={actual_sha}",
        f"provenance={provenance_path}",
        "candidate provenance bound to current commit and production key",
    ]


def _check_candidate(candidate: Path) -> list[str]:
    if not candidate.is_file():
        raise GateError(f"candidate archive not found: {candidate}")
    with zipfile.ZipFile(candidate) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise GateError("candidate archive contains duplicate entries")
        for name in names:
            if not _safe_zip_name(name):
                raise GateError(f"unsafe candidate path: {name}")
            if PRIVATE_NAME_RE.search(name):
                raise GateError(f"private-key-like candidate path: {name}")
        missing = [name for name in CANDIDATE_REQUIRED if name not in names]
        if missing:
            raise GateError("candidate missing signature assets: " + ", ".join(missing))
        verifier_info = archive.getinfo("bin/kpm-verify")
        mode = (verifier_info.external_attr >> 16) & 0xFFFF
        if mode and not (mode & 0o100):
            raise GateError("candidate bin/kpm-verify is not owner-executable")
        _check_static_aarch64_elf(archive.read("bin/kpm-verify"))
        for name in names:
            info = archive.getinfo(name)
            if info.file_size <= 1024 * 1024:
                data = archive.read(name)
                if any(marker in data for marker in PRIVATE_KEY_MARKERS):
                    raise GateError(f"candidate contains private-key material: {name}")
    return [f"candidate={candidate}", "static AArch64 verifier present"]


def check(root: Path, *, release_ready: bool, candidate: Path | None) -> dict:
    _scan_private_material(root)
    policy = ["python3", "scripts/verify_signing_key_policy.py", "--root", str(root)]
    if release_ready:
        policy.append("--release-ready")
    run(policy, cwd=root)
    run(["python3", "scripts/verify_monocypher_pin.py", "--root", str(root)], cwd=root)

    details = ["signing-key policy consistent", "Monocypher pin consistent", "no tracked private key material"]
    if candidate:
        resolved_candidate = candidate.resolve()
        details.extend(_check_candidate(resolved_candidate))
        if release_ready:
            details.extend(_check_candidate_provenance(root, resolved_candidate))
    elif release_ready:
        raise GateError("release-ready signature gate requires --candidate")

    return {
        "gate": "signature",
        "status": "pass",
        "releaseReady": release_ready,
        "summary": "Signing and verifier gate passed",
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--candidate")
    parser.add_argument("--release-ready", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        candidate = Path(args.candidate) if args.candidate else None
        emit(check(root_path(args.root), release_ready=args.release_ready, candidate=candidate), as_json=args.json)
        return 0
    except (GateError, zipfile.BadZipFile) as exc:
        print(f"ERROR: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
