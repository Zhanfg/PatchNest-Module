# PatchNest offline review status — 2026-08-07

Branch: `restart/offline-audit-suite`

This branch was developed without relying on GitHub Actions. It is intentionally
not merged and no release was created.

## Completed source work

### Boot target, patch, current-image unpatch, flash, and restore

- Added boot-only partition discovery; `vendor_boot*` and `init_boot*` are not
  valid KernelPatch targets.
- Added logical partition resolution through sysfs `PARTNAME` and by-name links.
- Added capacity, writable-state, write-result and exact-length SHA-256 readback
  verification for block-device writes.
- Disabled unverified character-device/NAND boot flashing.
- Added independently unpack-tested patch and unpatch outputs.
- Removed stale `new-boot.img` reuse.
- Added second+PID backup names and atomic verified manifests.
- Prevented an already patched boot image from replacing the recovery base.
- Removed shell tracing around potentially sensitive kptools arguments.
- Added file-only verified patch and current-image unpatch output.
- Added a no-eval compatibility layer for the WebUI's historically quoted
  `-A` argv values.
- Clarified that early boot records a recovery request; it does not claim that
  an automatic flash occurred.
- Separated current-image unpatch from verified-backup restoration:
  - `boot_unpatch.sh` only removes PatchNest from the selected current image;
  - `boot_restore_verified.sh` accepts one exact target and one exact backup;
  - restore defaults to validation-only and never chooses the newest backup.
- Replaced the misleading backup-plan unpatch dialog with an explicit current
  image operation model in English and Chinese.
- Added a one-time, root-owned, operation-bound, 120-second WebUI approval that
  is consumed before any unpatch processing begins. Direct CLI writes require
  a separate explicit environment approval.

### Module installation and lifecycle

- Removed the destructive fixed-path self-copy/hot-update path from
  `customize.sh`.
- Added package completeness checks for boot guards, explicit restore, argv
  normalization, quarantine management, binaries, and WebUI files.
- Added a validated `module.prop.bak` before runtime description updates.
- Preserved existing persistent user policy across upgrades.
- Changed uninstall cleanup to preserve verified boot backups and user state.
- Fixed delimiter-sensitive `module.prop` status updates.
- Resolved stale recovery-request JSON after a healthy `kpatch hello`.

### KPM admission, quarantine, and signatures

- Added ZIP entry preflight, rooted source paths, entry count, extraction size,
  symlink rejection and module-id validation.
- Rejected Linux `.ko/.o` objects and packages that do not contain exactly one
  prebuilt `.kpm`.
- Rejected imported C source packages at the installer boundary; device-side
  source compilation remains disabled.
- Required binary candidates to pass `kptools` parsing.
- Added staged installation and concurrent-install locking.
- Prevented unsigned modules from immediate loading or autoload marker creation.
- Quarantined all KPMs without explicit autoload before the legacy broad service
  scan.
- Quarantined every KPM when signature policy cannot be made unambiguous.
- Defaulted new/missing/duplicate/invalid signature policy to strict, while
  preserving one explicit valid off/warn/strict value.
- Corrected Ed25519 verification by wrapping the raw public key in RFC 8410 DER
  and using `openssl pkeyutl -rawin`.
- Removed predictable temporary-directory fallback and caller trap replacement.
- Converted quarantine entries from flat files into transaction directories
  containing canonical files, a manifest, state marker, and complete SHA-256
  checksum set.
- Added `manage_kpm_quarantine.sh` with read-only list/inspect and strict signed
  activation. Activation verifies the transaction, KPM parser result, and
  Ed25519 signature, refuses overwrite, stages changes, and rolls back failures.
  No delete or force command exists.
- Normalized retained package names to `${id}.zip` and `${id}.zip.sha256`, then
  revalidated the ZIP from its final persistent directory.

### Build, release, and offline verification

- Reworked local packaging around immutable dependency versions and pinned
  SHA-256 values.
- Removed mutable `latest` fallbacks and stale binary-cache trust.
- Added clean staging, normalized timestamps, sorted archive input and
  provenance output.
- Added release metadata consistency and optional local-asset SHA verification.
- Added a read-only Android evidence collector.
- Added a repository scanner, source contracts, fixture tests, signature vectors,
  argv vectors and source-only local verification entry point.
- Added JavaScript syntax parsing for all committed WebUI modules and tests.
- Added a second strict no-network WebUI entry point that uses an already
  prepared dependency tree and never runs `pnpm install`.
- Added release, device-matrix, KPM admission, source-build and local-test
  documentation.
- Added KSU profile and module-config input normalization plus Vitest coverage.
- Added pure WebUI tests for current-image unpatch semantics.

## Focused checks actually executed in the review environment

The environment could not clone the GitHub branch because outbound DNS was not
available. The complete branch suite has therefore not been represented as
executed.

The following focused checks were actually run:

1. The published Ed25519 probe signature verified successfully after RFC 8410
   DER wrapping with:

   ```text
   openssl pkeyutl -verify -pubin -keyform DER -rawin
   ```

2. The kptools argv normalization algorithm was executed with a captured mock
   argv. It preserved ordinary argument order and non-`-A` values, decoded
   spaces/quotes/dollar/backtick/exclamation/backslash escapes for `-A`, and
   rejected missing, mismatched, control-bearing and oversized values.

3. The one-time unpatch approval shell command was assembled and executed in an
   isolated directory. It produced the expected operation/timestamp marker,
   mode `0600`, and process-unique temporary path.

## Checks still mandatory

### Complete checkout

Run:

```sh
bash scripts/run_offline_checks.sh
```

With an already prepared lockfile dependency tree, run the strictly offline
WebUI suite:

```sh
bash scripts/run_webui_offline_checks.sh
```

Failures must be fixed on this branch before opening a mergeable PR.

### Package reproduction

Build twice from the same commit and `SOURCE_DATE_EPOCH`. Confirm identical ZIP
hashes and inspect `build-provenance.json`.

### Android compatibility

Test Android/BusyBox availability and behavior for:

- `mktemp -d`;
- `unzip -Z1`;
- `du -sk`;
- `sha256sum` and `sha256sum -c`;
- `openssl pkeyutl -keyform DER -rawin`;
- `dd iflag=fullblock conv=notrunc,fsync`;
- `blockdev --getsize64`, `--getbsz`, `--setrw`, `--getro`;
- `stat -c`, `readlink -f`, and shell trap reset behavior;
- sysfs `PARTNAME` and by-name mapping.

### Physical devices

The full `DEVICE_VALIDATION_MATRIX.md` remains pending, including A/B and
non-A/B patch, reboot, current-image unpatch, exact-backup validation/restore,
readback, failed-write and rollback evidence.

## Remaining source/UI blockers

1. The complete source-only and WebUI suites have not run from a full checkout.
2. Verified backup restoration currently has a conservative CLI interface only.
   A WebUI must display the exact target, exact backup, digest, manifest state,
   and separate confirmation before enabling restore writes.
3. Quarantine management has a verified backend but no WebUI list/inspect/
   activate surface yet.
4. The Ed25519 key is still identified as a development deployment key. Release
   signing custody, rotation and public provenance are not complete.
5. Device-side OpenSSL, shell-tool compatibility, direct restore, and the full
   KPM lifecycle remain untested.
6. The branch contains incremental content-API commits. Squash only after the
   complete local suite passes so the reviewed final tree is not rewritten
   prematurely.

## Release state

**Not ready to flash or release.**

The branch now has separate fail-closed patch, current-unpatch, and exact-restore
paths plus transactional KPM quarantine. Full local execution, recovery UI,
signing provenance, Android compatibility, and physical rollback evidence remain
mandatory.
