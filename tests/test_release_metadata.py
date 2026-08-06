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
kpimg_linux_0.13.3=7b8cf7e97169d2d73bba2e11653ad5bdbc6fc6251c5507b8d108f4a2e0bcd76f
kptools_android_0.13.3=ebf9b8eb17b4b3a6b1d4959402033bb1c6c4044d0e2532d480c34d1f412d5225
kpatch_android_0.13.5-2=d6a654816f11c8d297ca59aaace9c61537238f26191738c14610d2dcf39bf3b0
magisk_apk_v30.7=e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5
"""

GOOD_BUILD = """#!/usr/bin/env bash
download_assets "Zhanfg/KernelPatch-Public"
download_assets "Zhanfg/PatchNest"
download_assets "topjohnwu/Magisk"
printf x | sha256sum -c -
pnpm install --frozen-lockfile
"""


def update_payload(zip_sha: str = "a" * 64) -> dict[str, object]:
    return {
        "versionCode": 26,
        "version": "0.4.1-rc2",
        "zipUrl": "https://github.com/Zhanfg/PatchNest-Module/releases/download/v0.4.1-rc2/PatchNest-Module.zip",
        "changelog": "https://raw.githubusercontent.com/Zhanfg/PatchNest-Module/main/CHANGELOG.md",
        "zipSha256": zip_sha,
    }


def write_fixture(root: Path, *, module_prop: str = GOOD_MODULE_PROP, versions: str = GOOD_VERSIONS, build: str = GOOD_BUILD, update: dict[str, object] | None = None) -> None:
    (root / "module").mkdir(parents=True)
    (root / "module/module.prop").write_text(module_prop, encoding="utf-8")
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
            errors = VERIFY.verify(root)
            self.assertTrue(any("version does not match" in error for error in errors))

    def test_mutable_latest_dependency_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            versions = GOOD_VERSIONS.replace("kernelpatch=0.13.3", "kernelpatch=latest")
            write_fixture(root, versions=versions)
            errors = VERIFY.verify(root)
            self.assertTrue(any("mutable latest" in error for error in errors))

    def test_missing_dependency_digest_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            versions = GOOD_VERSIONS.replace(
                "kpimg_linux_0.13.3=7b8cf7e97169d2d73bba2e11653ad5bdbc6fc6251c5507b8d108f4a2e0bcd76f\n",
                "",
            )
            write_fixture(root, versions=versions)
            errors = VERIFY.verify(root)
            self.assertTrue(any("kpimg_linux_0.13.3" in error for error in errors))

    def test_local_asset_hash_is_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            asset = root / "PatchNest-Module.zip"
            asset.write_bytes(b"fixture-archive")
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            write_fixture(root, update=update_payload(digest))
            self.assertEqual([], VERIFY.verify(root, asset))
            asset.write_bytes(b"tampered")
            errors = VERIFY.verify(root, asset)
            self.assertTrue(any("SHA-256 mismatch" in error for error in errors))

    def test_wrong_release_asset_path_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = update_payload()
            payload["zipUrl"] = "https://github.com/Zhanfg/PatchNest-Module/releases/download/v0.4.1-rc2/other.zip"
            write_fixture(root, update=payload)
            errors = VERIFY.verify(root)
            self.assertTrue(any("zipUrl path" in error for error in errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)
