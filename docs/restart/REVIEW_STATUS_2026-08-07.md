# PatchNest offline review status — 2026-08-07

Branch: `restart/offline-audit-suite`

This branch was developed without relying on GitHub Actions. It is intentionally
not merged and no release was created.

## Completed source work

### Boot target, patch, flash and recovery

- Added boot-only partition discovery; `vendor_boot*` and `init_boot*` are not
  valid KernelPatch targets.
- Added logical partition resolution through sysfs `PARTNAME` and by-name links.
- Added capacity, writable-state, write-result and exact-length SHA-256 readback
  verification for block-device writes.
- Disabled unverified character-device/NAND boot flashing.
- Added independently unpack-tested patch and unpatch outputs.
- Removed stale `new-boot.img` reuse.
- Added target-bound, manifest-bound, digest-bound recovery selection.
- Added second+PID backup names and atomic verified manifests.
- Prevented an already patched boot image from replacing the recovery base.
- Removed shell tracing around potentially sensitive kptools arguments.
- Added file-only verified unpatch output.
- Added a no-eval compatibility layer for the WebUI's historically quoted
  `-A` argv values.
- Clarified that early boot records a recovery request; it does not claim that
  an automatic flash occurred.

### Module installation and lifecycle

- Removed the destructive fixed-path self-copy/hot-update path from
  `customize.sh`.
- Added package completeness checks for boot guards, binaries and WebUI files.
- Added a validated `module.prop.bak` before runtime description updates.
- Preserved existing persistent user policy across upgrades.
- Changed uninstall cleanup to preserve verified boot backups and user state.
- Fixed delimiter-sensitive `module.prop` status updates.
- Resolved stale recovery-request JSON after a healthy `kpatch hello`.

### KPM admission and signatures

- Added ZIP entry preflight, rooted source paths, entry count, extraction size,
  symlink rejection and module-id validation.
- Rejected Linux `.ko/.o` objects and ambiguous multi-binary packages.
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
- Disabled imported on-device KPM source compilation.

### Build, release and offline verification

- Reworked local packaging around immutable dependency versions and pinned
  SHA-256 values.
- Removed mutable `latest` fallbacks and stale binary-cache trust.
- Added clean staging, normalized timestamps, sorted archive input and
  provenance output.
- Added release metadata consistency and optional local-asset SHA verification.
- Added a read-only Android evidence collector.
- Added a repository scanner, source contracts, fixture tests, signature vectors,
  argv vectors and a one-command local verification entry point.
- Added release, device-matrix, KPM admission, source-build and local-test
  documentation.
- Added KSU profile and module-config input normalization plus Vitest coverage.

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

## Checks still mandatory

### Complete checkout

Run:

```sh
bash scripts/run_offline_checks.sh
```

Then run the WebUI tests/build:

```sh
cd webui
pnpm install --frozen-lockfile
pnpm test --run
pnpm build --emptyOutDir
```

Failures must be fixed on this branch before opening a mergeable PR.

### Package reproduction

Build twice from the same commit and `SOURCE_DATE_EPOCH`. Confirm identical ZIP
hashes and inspect `build-provenance.json`.

### Android compatibility

Test BusyBox/Android availability and behavior for:

- `mktemp -d`
- `unzip -Z1`
- `du -sk`
- `sha256sum`
- `openssl pkeyutl -keyform DER -rawin`
- `dd iflag=fullblock conv=notrunc,fsync`
- `blockdev --getsize64`, `--getbsz`, `--setrw`, `--getro`
- sysfs `PARTNAME` and by-name mapping

### Physical devices

The full `DEVICE_VALIDATION_MATRIX.md` remains pending, including A/B and
non-A/B patch, reboot, unpatch, readback, failed-write and rollback evidence.

## Remaining source/UI blockers

1. The WebUI normal-unpatch dialog still needs a dedicated change that clearly
   separates current-image unpatch from verified-backup restoration.
2. Quarantine management needs a WebUI surface before users can explicitly
   inspect, delete or re-admit disabled KPMs.
3. The retained KPM ZIP digest should be normalized to reference the final ZIP
   filename rather than its staging path.
4. The Ed25519 key is still identified as a development deployment key. Release
   signing custody, rotation and public provenance are not complete.
5. Device-side OpenSSL behavior and the complete KPM lifecycle are untested.
6. The branch contains incremental content-API commits. Squash only after the
   complete local suite passes so the reviewed final tree is not rewritten
   prematurely.

## Release state

**Not ready to flash or release.**

The branch materially improves fail-closed behavior and creates a testable
baseline, but full local execution, WebUI cleanup, signing provenance and
physical rollback evidence remain mandatory.
