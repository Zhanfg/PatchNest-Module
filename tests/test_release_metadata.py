#!/usr/bin/env python3
"""Unit tests for scripts/verify_release_metadata.py."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "patchnest_release_metadata", ROOT / "scripts/verify_release_metadata.py"
)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
SPEC.loader.exec_module(VERIFY)

GOOD_MODULE_PROP = """id=PatchNest
name=PatchNest
version=0.4.1-rc2
versionCode=26
updateJson=https://raw.githubusercontent.com/Zhanfg/PatchNest-Module/main/update.json
"""

GOOD_VERSIONS = """patchnest=0.13.5-2
kernelpatch=0.13.3
magiskboot=v30.7
monocypher=4.0.3
monocypher_commit=ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f
android_ndk=29.0.14206865
kpimg_linux_0.13.3=7b8cf7e97169d2d73bba2e11653ad5bdbc6fc6251c5507b8d108f4a2e0bcd76f
kptools_android_0.13.3=ebf9b8eb17b4b3a6b1d4959402033bb1c6c4044d0e2532d480c34d1f412d5225
kpatch_android_0.13.5-2=d6a654816f11c8d297ca59aaace9c61537238f26191738c14610d2dcf39bf3b0
magisk_apk_v30.7=e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5
monocypher_tar_4.0.3=8cc9bc341a66249016db9bd70e9142d8d0aef9945973744b1ac05dbc55d8ee66
"""

GOOD_BUILD = """#!/usr/bin/env bash
download_release_asset Zhanfg/KernelPatch-Public
download_release_asset Zhanfg/PatchNest
download_release_asset topjohnwu/Magisk
download_release_asset LoupVaillant/Monocypher
printf x | sha256sum -c - >&2
pnpm install --frozen-lockfile
ANDROID_NDK_HOME=/ndk
source.properties
aarch64-linux-android24-clang
module/tools/kpm-verify.c
echo 'native verifier accepted a tampered message'
echo 'Machine:[[:space:]]+AArch64'
echo 'unexpectedly has a dynamic interpreter'
cp Monocypher-LICENCE.md
python3 scripts/verify_signing_key_policy.py
KPM_SIGNING_PUBLIC_KEY=key
KPM_SIGNING_KEY_FINGERPRINT=fingerprint
KPM_SIGNING_KEY_STATUS=development
echo '\"kpmSigningPublicKey\"'
echo '\"kpmSigningKeyFingerprintSha256\"'
echo '\"kpmSigningKeyStatus\"'
echo 'release build requires a clean Git working tree'
echo '\"sourceTreeStatus\": \"clean\"'
SOURCE_DATE_EPOCH=1
zip -X -q archive.zip
cat > build-provenance.json
"""

GOOD_VERIFIER_SOURCE = """#define MAX_MESSAGE_SIZE 1
O_RDONLY | O_CLOEXEC | O_NOFOLLOW
S_ISREG(mode)
mmap(0, 1, PROT_READ, MAP_PRIVATE, 0, 0)
crypto_ed25519_check(signature, public_key, message, size)
crypto_wipe(key, size)
"""


def update_payload(zip_sha: str = "a" * 64) -> dict[str, object]:
    return {
        "versionCode": 26,
        "version": "0.4.1-rc2",
        "zipUrl": "https://github.com/Zhanfg/PatchNest-Module/releases/download/v0.4.1-rc2/PatchNest-Module.zip",
        "changelog": "https://raw.githubusercontent.com/Zhanfg/PatchNest-Module/main/CHANGELOG.md",
        "zipSha256": zip_sha,
    }


def write_fixture(
    root: Path,
    *,
    module_prop: str = GOOD_MODULE_PROP,
    versions: str = GOOD_VERSIONS,
    build: str = GOOD_BUILD,
    verifier_source: str = GOOD_VERIFIER_SOURCE,
    update: dict[str, object] | None = None,
) -> None:
    (root / "module/tools").mkdir(parents=True)
    (root / "module/module.prop").write_text(module_prop, encoding="utf-8")
    (root / "module/tools/kpm-verify.c").write_text(verifier_source, encoding="utf-8")
    (root / "version.properties").write_text(versions, encoding="utf-8")
    (root / "build.sh").write_text(build, encoding="utf-8")
    (root / "update.json").write_text(
        json.dumps(update or update_payload(), indent=2) + "\n",
        encoding="utf-8",
    )


class ReleaseMetadataTests(unittest.TestCase):
    def test_repository_metadata_is_consistent(self):
        self.assertEqual([], VERIFY.verify(ROOT))

    def test_valid_fixture_passes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root)
            self.assertEqual([], VERIFY.verify(root))

    def test_version_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = update_payload()
            payload["version"] = "0.4.2"
            write_fixture(root, update=payload)
            self.assertTrue(any("version does not match" in error for error in VERIFY.verify(root)))

    def test_mutable_latest_dependency_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            versions = GOOD_VERSIONS.replace("kernelpatch=0.13.3", "kernelpatch=latest")
            write_fixture(root, versions=versions)
            self.assertTrue(any("mutable latest" in error for error in VERIFY.verify(root)))

    def test_missing_dependency_digest_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            versions = GOOD_VERSIONS.replace(
                "monocypher_tar_4.0.3=8cc9bc341a66249016db9bd70e9142d8d0aef9945973744b1ac05dbc55d8ee66\n",
                "",
            )
            write_fixture(root, versions=versions)
            self.assertTrue(any("monocypher_tar_4.0.3" in error for error in VERIFY.verify(root)))

    def test_invalid_monocypher_commit_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            versions = GOOD_VERSIONS.replace(
                "monocypher_commit=ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f",
                "monocypher_commit=bad",
            )
            write_fixture(root, versions=versions)
            self.assertTrue(any("monocypher_commit" in error for error in VERIFY.verify(root)))

    def test_invalid_ndk_revision_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            versions = GOOD_VERSIONS.replace("android_ndk=29.0.14206865", "android_ndk=r29")
            write_fixture(root, versions=versions)
            self.assertTrue(any("android_ndk" in error for error in VERIFY.verify(root)))

    def test_missing_signing_provenance_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            build = GOOD_BUILD.replace('echo \'"kpmSigningKeyStatus"\'\n', "")
            write_fixture(root, build=build)
            self.assertTrue(any("kpmSigningKeyStatus" in error for error in VERIFY.verify(root)))

    def test_missing_verifier_source_behavior_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, verifier_source=GOOD_VERIFIER_SOURCE.replace("crypto_ed25519_check", "removed"))
            self.assertTrue(any("crypto_ed25519_check" in error for error in VERIFY.verify(root)))

    def test_local_asset_hash_is_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            asset = root / "PatchNest-Module.zip"
            asset.write_bytes(b"fixture-archive")
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            write_fixture(root, update=update_payload(digest))
            self.assertEqual([], VERIFY.verify(root, asset))
            asset.write_bytes(b"tampered")
            self.assertTrue(any("SHA-256 mismatch" in error for error in VERIFY.verify(root, asset)))

    def test_wrong_release_asset_path_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = update_payload()
            payload["zipUrl"] = "https://github.com/Zhanfg/PatchNest-Module/releases/download/v0.4.1-rc2/other.zip"
            write_fixture(root, update=payload)
            self.assertTrue(any("zipUrl path" in error for error in VERIFY.verify(root)))

    def test_stdout_progress_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_fixture(root, build=GOOD_BUILD + 'echo "Downloading $asset_name"\n')
            self.assertTrue(any("command-substitution" in error for error in VERIFY.verify(root)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
