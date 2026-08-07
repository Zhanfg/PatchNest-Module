# PatchNest offline review status — 2026-08-07

Branch: `restart/offline-audit-suite`

The branch remains isolated from `main`. No tag, GitHub Release, `update.json`
change, or physical block-device write has been performed.

## Current source baseline

### Boot patch, unpatch, and exact restore

- KernelPatch target discovery is restricted to kernel-bearing boot aliases;
  `vendor_boot*` and `init_boot*` are rejected.
- The legacy public `find_boot_image()` name is overridden by the boot-only
  resolver, and repository contracts reject new direct legacy callers.
- Direct writes enforce target type/name, image/partition capacity, writable
  state, write result, and exact-length SHA-256 readback.
- Character-device/NAND boot flashing remains disabled because equivalent
  readback guarantees have not been established.
- A strict read-only runtime compatibility probe runs immediately before
  `blockdev --setrw` and `dd`; failure returns code 8 and performs no write.
- Current-image unpatch and exact verified-backup restore are separate paths.
- Restore never auto-selects the newest backup and requires exact target, file,
  manifest, digest, and one-time approval binding.
- Intentional unpatch/restore suspends failed-boot counting until a healthy
  `kpatch hello` resumes monitoring.

### KPM installation and lifecycle

- Imported packages are bounded and preflighted for path traversal, duplicate
  entries, declared/actual extraction size, symlinks, duplicate metadata keys,
  ambiguous binaries/signatures, and invalid module IDs.
- Device-side source compilation is disabled; exactly one prebuilt `.kpm` is
  required.
- Persistent installation uses staged state, an owned lock, a durable journal,
  crash recovery, update rollback, and final ZIP digest revalidation.
- Early admission and runtime failures share one transaction format with
  manifests, state markers, and complete SHA-256 checksum sets.
- Quarantine entries support read-only list/inspect and strict signed activation.
- Runtime failed entries are visible but remain non-activatable.
- The WebUI exposes quarantine/failed inspection and exact verified-backup
  validation/restore; failed transactions remain read-only.

### Packaged signature verifier

- Android no longer assumes the ROM provides a compatible OpenSSL binary.
- The package is designed to include static AArch64 `bin/kpm-verify`, built from
  the minimal read-only wrapper in `module/tools/kpm-verify.c` and pinned
  Monocypher 4.0.3 sources.
- Monocypher release asset SHA-256, tag commit, Android NDK revision, licence,
  host valid/tampered vectors, AArch64 ELF type, and no-dynamic-interpreter
  checks are represented in the build and metadata gates.
- OpenSSL remains only an explicit host-test fallback.
- The configured public key, shell source key, and raw-key SHA-256 fingerprint
  are machine checked.
- The current signing key is explicitly `development`; release-candidate
  construction fails before network or build work until a production key and
  custody evidence are installed.

### Runtime compatibility and evidence

- `runtime_compat_check.sh` provides read-only stdout, persisted, and strict
  modes.
- It checks packaged executables, shell/coreutils behavior, temporary-file `dd`
  flags, the packaged verifier self-test, blockdev option support, and boot
  target mapping without executing `blockdev --setrw`.
- `collect_device_evidence.sh` attaches the strict compatibility output and exit
  status while continuing other evidence collection on probe failure.
- The collector's historical brace-group bug, which terminated collection after
  the first command, is fixed by per-command subshell execution.

## Verification actually completed

### Complete suites on an earlier pre-verifier tree

Before adding the packaged Monocypher/NDK verifier supply chain, a full checkout
successfully completed the source-only suite, transaction suite, WebUI Vitest,
Vite production build, and byte-identical double package build. Those results
remain useful for unchanged areas, but they are **not** presented as validation
of the current verifier/build changes.

### Focused checks on the current verifier work

The following current-file or same-content focused checks have been executed:

- `kpm-verify.c` compiled against a strict API stub and passed valid, tampered,
  malformed-hex, symlink, oversized-file, and usage/exit-status vectors;
- `kpm_verify.sh` passed default fail-closed, explicit host OpenSSL fallback,
  packaged-backend preference, tamper, malformed, oversized, and symlink vectors;
- runtime compatibility host fixture passed before the packaged-backend switch;
- device evidence fixture passed, including continued collection after a failed
  compatibility probe;
- pre-write compatibility gate fixture and ordering contract passed;
- signing-key consistency/release-readiness focused vectors passed;
- Monocypher tag/release metadata fixtures passed for valid metadata and rejected
  commit, digest, URL, state, and duplicate-asset changes;
- release metadata focused consistency verification passed after moving verifier
  API checks to the C source file.

## Mandatory checks not yet completed on the current tree

1. Run the complete current 22-step source-only suite from a fresh checkout:

   ```sh
   bash scripts/run_offline_checks.sh
   ```

2. Run the strict offline WebUI suite from the same commit:

   ```sh
   bash scripts/run_webui_offline_checks.sh
   ```

3. Install Android NDK revision `29.0.14206865`, run a clean full build, and
   confirm the official Monocypher asset download, real host Ed25519 vectors,
   static AArch64 cross-link, ELF checks, licence packaging, and provenance.

4. Build twice from the same clean commit and `SOURCE_DATE_EPOCH`; require
   byte-identical ZIP, `.sha256`, and provenance output.

5. Execute `runtime_compat_check.sh --strict` and the complete device evidence
   collector on each physical test device.

6. Complete the A/B and non-A/B matrix for patch, reboot, current-image unpatch,
   exact restore, readback mismatch, failed write, and rollback.

7. Replace the development KPM signing key with a production key whose private
   material has documented custody, independent public-key verification, and a
   tested rotation/revocation process. Then pass:

   ```sh
   python3 scripts/verify_signing_key_policy.py --release-ready
   ```

## Release state

**Not ready to flash or release.**

The remaining blockers are now explicit: current-tree full-suite execution,
pinned-NDK/real-Monocypher cross-build evidence, production signing-key custody,
and physical device patch/rollback validation. The branch must not be merged or
published until those gates pass on one frozen commit.
