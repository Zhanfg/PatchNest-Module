#!/usr/bin/env python3
"""Verify PatchNest release metadata without network access."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SEMVERISH = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
NDK_REVISION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def parse_kv(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{line_number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        if not key:
            raise ValueError(f"{path}:{line_number}: empty key")
        if key in result:
            raise ValueError(f"{path}:{line_number}: duplicate key {key}")
        result[key] = value
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(root: Path, release_asset: Path | None = None) -> list[str]:
    errors: list[str] = []
    module_prop = parse_kv(root / "module/module.prop")
    versions = parse_kv(root / "version.properties")
    update = json.loads((root / "update.json").read_text(encoding="utf-8"))
    build = (root / "build.sh").read_text(encoding="utf-8")
    verifier_source = (root / "module/tools/kpm-verify.c").read_text(encoding="utf-8")

    module_version = module_prop.get("version", "")
    module_code_raw = module_prop.get("versionCode", "")
    if not SEMVERISH.fullmatch(module_version):
        errors.append(f"module.prop version is not semver-like: {module_version!r}")
    try:
        module_code = int(module_code_raw)
    except ValueError:
        module_code = -1
        errors.append(f"module.prop versionCode is not an integer: {module_code_raw!r}")

    if update.get("version") != module_version:
        errors.append("update.json version does not match module.prop")
    if update.get("versionCode") != module_code:
        errors.append("update.json versionCode does not match module.prop")

    zip_url = str(update.get("zipUrl", ""))
    parsed_zip = urlparse(zip_url)
    expected_tag = f"v{module_version}"
    expected_path = f"/Zhanfg/PatchNest-Module/releases/download/{expected_tag}/PatchNest-Module.zip"
    if parsed_zip.scheme != "https" or parsed_zip.netloc != "github.com":
        errors.append("zipUrl must be an HTTPS github.com Release asset")
    if parsed_zip.path != expected_path:
        errors.append(f"zipUrl path must be {expected_path!r}, got {parsed_zip.path!r}")

    zip_sha = str(update.get("zipSha256", ""))
    if not HEX64.fullmatch(zip_sha):
        errors.append("update.json zipSha256 must be 64 lowercase hex characters")

    if module_prop.get("updateJson") != "https://raw.githubusercontent.com/Zhanfg/PatchNest-Module/main/update.json":
        errors.append("module.prop updateJson must point to the main-branch update.json")
    if update.get("changelog") != "https://raw.githubusercontent.com/Zhanfg/PatchNest-Module/main/CHANGELOG.md":
        errors.append("update.json changelog must point to main/CHANGELOG.md")

    dependency_keys = {
        "kernelpatch": ["kpimg_linux", "kptools_android"],
        "patchnest": ["kpatch_android"],
        "magiskboot": ["magisk_apk"],
        "monocypher": ["monocypher_tar"],
    }
    for version_key, digest_prefixes in dependency_keys.items():
        version = versions.get(version_key, "")
        if not version:
            errors.append(f"version.properties missing {version_key}")
            continue
        if version.lower() == "latest":
            errors.append(f"{version_key} must not use mutable latest")
        for prefix in digest_prefixes:
            digest_key = f"{prefix}_{version}"
            if not HEX64.fullmatch(versions.get(digest_key, "")):
                errors.append(f"missing or invalid trusted digest: {digest_key}")

    if not HEX40.fullmatch(versions.get("monocypher_commit", "")):
        errors.append("version.properties monocypher_commit must be 40 lowercase hex characters")
    if not NDK_REVISION.fullmatch(versions.get("android_ndk", "")):
        errors.append("version.properties android_ndk must be a full numeric revision")

    required_build_tokens = [
        "download_release_asset",
        "Zhanfg/KernelPatch-Public",
        "Zhanfg/PatchNest",
        "topjohnwu/Magisk",
        "LoupVaillant/Monocypher",
        "sha256sum -c - >&2",
        "pnpm install --frozen-lockfile",
        "ANDROID_NDK_HOME",
        "source.properties",
        "aarch64-linux-android24-clang",
        "module/tools/kpm-verify.c",
        "native verifier accepted a tampered message",
        "Machine:[[:space:]]+AArch64",
        "unexpectedly has a dynamic interpreter",
        "Monocypher-LICENCE.md",
        "verify_signing_key_policy.py",
        "KPM_SIGNING_PUBLIC_KEY",
        "KPM_SIGNING_KEY_FINGERPRINT",
        "KPM_SIGNING_KEY_STATUS",
        '"kpmSigningPublicKey"',
        '"kpmSigningKeyFingerprintSha256"',
        '"kpmSigningKeyStatus"',
        "release build requires a clean Git working tree",
        '"sourceTreeStatus": "clean"',
        "SOURCE_DATE_EPOCH",
        "zip -X -q",
        "build-provenance.json",
    ]
    for token in required_build_tokens:
        if token not in build:
            errors.append(f"build.sh is missing required integrity behavior: {token}")

    required_verifier_tokens = [
        "crypto_ed25519_check",
        "O_RDONLY | O_CLOEXEC | O_NOFOLLOW",
        "MAX_MESSAGE_SIZE",
        "S_ISREG",
        "PROT_READ, MAP_PRIVATE",
        "crypto_wipe",
    ]
    for token in required_verifier_tokens:
        if token not in verifier_source:
            errors.append(f"kpm-verify.c is missing required verifier behavior: {token}")

    if re.search(r"VERSION_[A-Z_]+=.*latest", build):
        errors.append("build.sh contains a mutable latest fallback for a release dependency")
    if 'echo "Downloading $asset_name"\n' in build:
        errors.append("download progress is written to stdout and can corrupt command-substitution paths")

    if release_asset is not None:
        if not release_asset.is_file():
            errors.append(f"release asset not found: {release_asset}")
        else:
            actual = sha256_file(release_asset)
            if actual != zip_sha:
                errors.append(f"release asset SHA-256 mismatch: expected {zip_sha}, got {actual}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--release-asset", type=Path)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    try:
        errors = verify(root, args.release_asset)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Release metadata verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
