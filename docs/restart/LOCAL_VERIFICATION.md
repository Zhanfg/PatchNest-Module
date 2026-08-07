# PatchNest local verification without GitHub Actions

The branch `restart/offline-audit-suite` is designed to be reviewed and tested
without consuming GitHub Actions minutes.

## Host requirements

For source-only checks:

- Bash;
- Python 3.11+;
- a C compiler (`cc`);
- OpenSSL with Ed25519 `pkeyutl -rawin` for the explicit host fallback vectors;
- Node.js;
- standard GNU coreutils.

For the WebUI suite, an existing lockfile-matched pnpm dependency tree is also
required.

For a complete package build:

- network access to the official GitHub Release assets;
- pnpm;
- jq, curl, unzip, zip, tar, readelf, and sha256sum;
- `ANDROID_NDK_HOME` pointing to Android NDK revision exactly
  `29.0.14206865`.

The source-only checks require no network, Android root, boot image, attached
device, package download, or GitHub Actions runner.

## Source-only suite

From a complete checkout:

```sh
bash scripts/run_offline_checks.sh
```

The suite currently covers:

- Python syntax and fixture tests;
- boot target, patch, unpatch, exact restore, and flash ordering contracts;
- legacy boot/flash helper containment;
- KPM install, journal, transaction, quarantine, and signature lifecycle;
- packaged verifier CLI compilation against a strict API stub;
- runtime compatibility, device evidence, and pre-write gate host vectors;
- Monocypher GitHub metadata fixtures;
- signing-key public-key/fingerprint consistency;
- the deliberate development-key Release block;
- release metadata/provenance contracts;
- shell and JavaScript syntax parsing;
- repository audit report generation.

Reports are written to `audit-output/`, which is ignored by Git.

## Strict no-network WebUI suite

```sh
bash scripts/run_webui_offline_checks.sh
```

This script never installs or downloads packages. It requires an already
prepared `webui/node_modules` matching the committed lockfile. To prepare it
once in a network-enabled environment:

```sh
cd webui
pnpm install --frozen-lockfile
cd ..
```

Then disconnect the network and run the strict offline script. It performs
JavaScript syntax parsing, the complete Vitest suite, and a Vite production
build from the existing dependency tree.

## Boot operation boundaries

Three operations are intentionally separate:

- `boot_patch.sh`: patch the selected current boot image;
- `boot_unpatch.sh`: remove PatchNest from the selected current boot image;
- `boot_restore_verified.sh`: validate or explicitly restore one exact,
  target-bound verified backup.

`boot_unpatch.sh` never selects a backup. `boot_restore_verified.sh` defaults to
validation-only mode and never selects the newest backup automatically.

Every direct block write repeats `runtime_compat_check.sh --strict` before
`blockdev --setrw` and `dd`. Compatibility failure code 8 means no write was
attempted.

## KPM transaction inspection

Quarantine entries:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh list
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh inspect <entry-id>
```

Runtime failed entries are read-only:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh list failed
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh inspect failed <entry-id>
```

Only a complete, checksummed, parseable, correctly signed quarantine transaction
can be activated. There is no force-overwrite or delete command.

## Test-candidate package build

The normal build permits the explicitly labelled development signing key. It is
for local and physical-device validation only:

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk-r29
bash build.sh
```

The build:

- requires a clean Git tree;
- verifies pinned dependency SHA-256 values;
- downloads official Monocypher 4.0.3 sources;
- compiles and runs real host valid/tampered Ed25519 vectors;
- cross-compiles static AArch64 `bin/kpm-verify` and `bin/kp-safemode`;
- rejects a dynamic interpreter;
- packages the Monocypher licence;
- records dependency, verifier, public-key fingerprint, and key-status
  provenance.

Expected outputs:

```text
out/PatchNest-Module.zip
out/PatchNest-Module.zip.sha256
out/build-provenance.json
```

Build twice from the same clean commit and `SOURCE_DATE_EPOCH`; require all
three outputs to be byte-identical.

## Publishable Release candidate

Use the release wrapper rather than calling `build.sh` directly:

```sh
export ANDROID_NDK_HOME=/path/to/android-ndk-r29
bash scripts/build_release_candidate.sh
```

It enforces, in order:

1. production signing-key readiness;
2. official Monocypher Git tag commit and GitHub Release asset metadata;
3. repository release metadata consistency;
4. the normal clean, pinned, reproducible build.

The command currently fails before network access because the repository key is
intentionally marked `development`. That is the correct state until production
private-key custody, independent public-key verification, rotation, revocation,
and physical-device signature evidence exist.

## Optional released-asset check

```sh
python3 scripts/verify_release_metadata.py \
  --release-asset out/PatchNest-Module.zip
```

This compares the local file with the SHA-256 currently recorded in
`update.json`. It should fail for an unpublished candidate while `update.json`
continues to describe the existing immutable Release asset.

## Android compatibility and evidence

On the installed candidate:

```sh
su -c 'sh /data/adb/modules/PatchNest/runtime_compat_check.sh --strict'
```

Collect read-only evidence:

```sh
su -c 'sh /data/adb/modules/PatchNest/scripts/collect_device_evidence.sh'
```

The collector attaches the compatibility console output and exit status. The
default does not hash the complete boot partition; add `--hash-boot` only when a
read-only active-boot digest is required.

Review all properties and logs before sharing. Device identifiers can appear in
the archive.

## Current validation boundary

A complete older pre-verifier tree previously passed source, WebUI, transaction,
and reproducible package checks. After introducing the pinned Monocypher/NDK
verifier supply chain, focused current-file tests have passed, but the **current
full checkout, exact NDK cross-build, double-build reproduction, and physical
device matrix remain mandatory**. See `REVIEW_STATUS_2026-08-07.md` for the
precise completed/pending split.
