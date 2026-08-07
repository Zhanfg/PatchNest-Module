#!/usr/bin/env python3
"""Static contracts for the packaged Monocypher Ed25519 verifier."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = (ROOT / "version.properties").read_text(encoding="utf-8")
BUILD = (ROOT / "build.sh").read_text(encoding="utf-8")
SOURCE = (ROOT / "module/tools/kpm-verify.c").read_text(encoding="utf-8")
SHELL = (ROOT / "module/kpm_verify.sh").read_text(encoding="utf-8")
CUSTOMIZE = (ROOT / "module/customize.sh").read_text(encoding="utf-8")
RUNTIME = (ROOT / "module/runtime_compat_check.sh").read_text(encoding="utf-8")
RUNNER = (ROOT / "scripts/run_offline_checks.sh").read_text(encoding="utf-8")

for token, message in {
    'monocypher="4.0.3"': "Monocypher version is not pinned",
    'monocypher_commit="ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f"': "Monocypher tag commit is not pinned",
    'android_ndk="29.0.14206865"': "Android NDK revision is not pinned",
    'monocypher_tar_4.0.3=8cc9bc341a66249016db9bd70e9142d8d0aef9945973744b1ac05dbc55d8ee66': "Monocypher release digest is not pinned",
}.items():
    if token not in VERSIONS:
        raise AssertionError(message)

for token, message in {
    "LoupVaillant/Monocypher": "build does not use the official Monocypher repository",
    "monocypher-${VERSION_MONOCYPHER}.tar.gz": "build does not select the exact release asset",
    "ANDROID_NDK_HOME": "build does not require an Android NDK",
    "source.properties": "build does not validate the NDK revision",
    "aarch64-linux-android24-clang": "build does not use an Android AArch64 compiler",
    "native verifier accepted a tampered message": "build does not run a tampered-message vector",
    "-static -fPIE -pie": "Android verifier is not linked as a static PIE",
    "Machine:[[:space:]]+AArch64": "build does not verify AArch64 ELF metadata",
    "unexpectedly has a dynamic interpreter": "build does not reject a dynamic interpreter",
    "Monocypher-LICENCE.md": "package does not include the Monocypher licence",
    '"kpmVerifier": "static-monocypher-ed25519"': "provenance omits the verifier backend",
    '"sourceTreeStatus": "clean"': "provenance does not assert a clean tree",
}.items():
    if token not in BUILD:
        raise AssertionError(message)

for token, message in {
    "crypto_ed25519_check": "verifier does not call the Monocypher Ed25519 API",
    "O_RDONLY | O_CLOEXEC | O_NOFOLLOW": "message file is not opened read-only/no-follow",
    "MAX_MESSAGE_SIZE": "message size is not bounded",
    "S_ISREG": "message input is not restricted to a regular file",
    "mmap(NULL, size, PROT_READ, MAP_PRIVATE": "message mapping is not read-only/private",
    "crypto_wipe": "key and signature buffers are not wiped",
    "return check == 0 ? 0 : 1": "valid and invalid signatures do not have stable exit statuses",
}.items():
    if token not in SOURCE:
        raise AssertionError(message)

for token, message in {
    "kpm_verify__require_binary": "packaged backend loader is missing",
    "bin/kpm-verify": "packaged verifier path is missing",
    "KPM_VERIFY_BACKEND=binary": "packaged backend is not identified",
    'KPM_VERIFY_ALLOW_OPENSSL_FALLBACK:-0}" = "1"': "OpenSSL fallback is not explicit opt-in",
    "packaged Ed25519 verifier unavailable; failing closed": "missing backend does not fail closed",
}.items():
    if token not in SHELL:
        raise AssertionError(message)
if SHELL.find("kpm_verify__require_binary") > SHELL.find("kpm_verify__require_openssl"):
    raise AssertionError("OpenSSL is attempted before the packaged verifier")

for package_path in ("bin/kpm-verify", "bin/kp-safemode"):
    if package_path not in CUSTOMIZE:
        raise AssertionError(f"installer does not require {package_path}")
if "ed25519_verifier" not in RUNTIME or "kpm_verify__require_backend" not in RUNTIME:
    raise AssertionError("runtime probe does not verify the packaged backend")
if "kpm_verify__require_openssl" in RUNTIME:
    raise AssertionError("runtime probe still requires system OpenSSL")

for path in (
    "tests/test_kpm_verify_cli_source.sh",
    "tests/validate_packaged_kpm_verifier.py",
):
    if path not in RUNNER:
        raise AssertionError(f"{path} is not included in the offline runner")

print("Packaged KPM verifier contracts validated.")
