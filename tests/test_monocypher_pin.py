#!/usr/bin/env python3
"""Unit tests for scripts/verify_monocypher_pin.py."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "patchnest_monocypher_pin", ROOT / "scripts/verify_monocypher_pin.py"
)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
SPEC.loader.exec_module(VERIFY)

VERSION = "4.0.3"
COMMIT = "ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f"
DIGEST = "8cc9bc341a66249016db9bd70e9142d8d0aef9945973744b1ac05dbc55d8ee66"
NAME = f"monocypher-{VERSION}.tar.gz"
URL = f"https://github.com/LoupVaillant/Monocypher/releases/download/{VERSION}/{NAME}"


def tag_payload() -> dict[str, object]:
    return {
        "ref": f"refs/tags/{VERSION}",
        "object": {"type": "commit", "sha": COMMIT},
    }


def release_payload() -> dict[str, object]:
    return {
        "tag_name": VERSION,
        "draft": False,
        "prerelease": False,
        "assets": [
            {
                "name": NAME,
                "state": "uploaded",
                "size": 940390,
                "digest": f"sha256:{DIGEST}",
                "browser_download_url": URL,
            }
        ],
    }


class MonocypherPinTests(unittest.TestCase):
    def validate(self, tag=None, release=None):
        return VERIFY.validate_payloads(
            version=VERSION,
            expected_commit=COMMIT,
            expected_digest=DIGEST,
            tag_payload=tag or tag_payload(),
            release_payload=release or release_payload(),
        )

    def test_valid_metadata_passes(self):
        self.assertEqual([], self.validate())

    def test_api_headers_add_token_only_when_supplied(self):
        without = VERIFY.request_headers()
        with_token = VERIFY.request_headers("test-token")
        self.assertNotIn("Authorization", without)
        self.assertEqual("Bearer test-token", with_token["Authorization"])
        self.assertEqual("application/vnd.github+json", with_token["Accept"])

    def test_fetch_rejects_credentials_outside_pinned_api_root(self):
        with self.assertRaisesRegex(ValueError, "outside the pinned API root"):
            VERIFY.fetch_json("https://example.invalid/resource", token="secret")

    def test_tag_commit_mismatch_fails(self):
        tag = tag_payload()
        tag["object"] = {"type": "commit", "sha": "0" * 40}
        self.assertTrue(any("tag commit mismatch" in error for error in self.validate(tag=tag)))

    def test_annotated_or_non_commit_tag_fails(self):
        tag = tag_payload()
        tag["object"] = {"type": "tag", "sha": COMMIT}
        self.assertTrue(any("point directly to a commit" in error for error in self.validate(tag=tag)))

    def test_draft_and_prerelease_fail(self):
        release = release_payload()
        release["draft"] = True
        release["prerelease"] = True
        errors = self.validate(release=release)
        self.assertTrue(any("draft" in error for error in errors))
        self.assertTrue(any("prerelease" in error for error in errors))

    def test_asset_digest_mismatch_fails(self):
        release = release_payload()
        release["assets"][0]["digest"] = "sha256:" + "0" * 64
        self.assertTrue(any("digest mismatch" in error for error in self.validate(release=release)))

    def test_duplicate_asset_fails(self):
        release = release_payload()
        release["assets"].append(dict(release["assets"][0]))
        self.assertTrue(any("exactly one" in error for error in self.validate(release=release)))

    def test_wrong_download_url_fails(self):
        release = release_payload()
        release["assets"][0]["browser_download_url"] = URL + ".mirror"
        self.assertTrue(any("download URL mismatch" in error for error in self.validate(release=release)))

    def test_invalid_asset_state_or_size_fails(self):
        release = release_payload()
        release["assets"][0]["state"] = "new"
        release["assets"][0]["size"] = 0
        errors = self.validate(release=release)
        self.assertTrue(any("uploaded state" in error for error in errors))
        self.assertTrue(any("size is invalid" in error for error in errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)
