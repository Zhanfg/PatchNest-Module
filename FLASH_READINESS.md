# PatchNest flash-readiness review

Status: **NOT FLASH READY — STATIC/CODE GATES CLOSED, PHYSICAL DEVICE GATE OPEN**

This document is the live release gate for `review/flash-readiness-hardening`.
`module/FLASH_REVIEW_BLOCKED` intentionally keeps the review branch non-installable.
Green CI is necessary but is **not** sufficient evidence for a boot-image modifying
release.

Reviewed code/package baseline before this documentation commit:

`63d94f480cddf398e76cfa2ca6826e7ce3e455c4`

Verified at that baseline:

- `Build` run `31233359168`: **PASS**
  - source/release metadata validation;
  - shell syntax + ShellCheck;
  - WebUI tests + production build;
  - pinned external dependency SHA-256 validation;
  - exact-source Public1158 userspace rebuild;
  - ARM64 ABI/profile inspection;
  - complete module validation;
  - deterministic double-package byte comparison;
  - verified artifact upload.
- `Flash safety` run `31233359159`: **PASS**
  - transactional writer tests;
  - superkey transaction tests;
  - device/transaction-bound rollback tests;
  - runtime ABI capability contract;
  - physical validation harness syntax/ShellCheck.

## Resolved static findings

### FR-001 — mixed userspace/kernel ABI family — **RESOLVED**

The package no longer combines Public1158 kernel components with the historical
Next2026 `kpatch-android` release binary.

`version.properties` pins reviewed PatchNest source commit:

`7fed93c4e259a6edf191c1a9900874babb232c4b`

and the module build independently compiles `kpatch-public1158` for Android ARM64.
The package provenance records the source commit and resulting binary SHA-256.

The compatibility target is explicit rather than runtime mutation probing:

- Public1158 token: `0x1158`;
- hello: `0x11581158` / `hello1158`;
- superkey-authenticated sensitive operations;
- KPM / kstorage exclusion supported;
- Public KPM event command `0x1150` supported through an event allowlist;
- rehook forbidden because Public `0x1100/0x1101` mean SU grant/revoke, while
  Next2026 uses those IDs for rehook operations.

`service.sh` accepts only exact `hello1158` / `hello2026` responses and derives
runtime capability from the resulting profile. Unknown successful hello output is
rejected.

### FR-002 — shared patch workspace / stale image reuse — **RESOLVED**

Patch and unpatch use operation-private `mktemp -d` workspaces, freshly unpack the
requested boot target and clean the workspace with traps. The historical
"reuse kernel if present" path is rejected by CI.

### FR-003 — rollback not bound to exact target/device/transaction — **RESOLVED IN CODE**

A destructive write creates a unique validated rollback backup. Automatic restore no
longer scans or chooses a "latest" backup.

The committed rollback transaction binds:

- canonical boot target;
- SHA-256 of device identity derived from boot serial + product/vbmeta/slot context;
- one exact rollback backup filename and SHA-256;
- exact patched-image SHA-256 and written byte length;
- superkey digest;
- verified-readback state.

Only the device-identity digest is persisted; the raw serial is not stored.
Synthetic device identity is accepted only when `PATCHNEST_TRANSACTION_TEST=1` for
CI and cannot replace production identity resolution.

`boot_unpatch.sh --restore-bound-backup` verifies the device/slot/target context,
backup digest and the current patched byte range before any restore write. External
reflash, device mismatch or stale transaction state therefore fails closed.

### FR-004 — destructive flash without mandatory readback — **RESOLVED**

The reviewed writer performs payload normalization, capacity/read-only checks,
write + fsync/sync, then SHA-256 readback over the exact written byte range.
Digest mismatch is a hard failure.

### FR-005 — root-shell `eval` fallback — **RESOLVED**

Reviewed patch/unpatch/extract paths source `flash_safety.sh`, whose config assignment
uses an explicit allowlisted switch. No root-shell `eval` is used by this path.

### FR-006 — ambiguous A/B boot target / vendor_boot guessing — **RESOLVED**

The resolver accepts only `_a` / `_b` slot suffixes, refuses A/B devices when the
active slot cannot be established, resolves the matching boot partition only and
does not treat `vendor_boot` / `init_boot` as generic boot substitutes.

### FR-007 — block-device backup/hash gap — **RESOLVED**

Backup capture hashes the actual boot target and captured bytes regardless of whether
the source is a regular file or block device. Target and backup digests must match
before patching. Rollback also verifies the currently written patched byte range.

### FR-008 — backup name collision — **RESOLVED**

Backup names use UTC second precision plus `mktemp` uniqueness. Rollback selection is
transaction-bound, not filename-order based.

### FR-009 — embedded KPM validation fail-open — **RESOLVED**

Each embedded `-M` candidate must be an absolute existing file, contain ELF magic,
be AArch64, pass `kptools -l -M` and expose a non-empty module name. Failure aborts
before boot-image mutation.

### FR-010 — KPM argument contract mismatch — **RESOLVED**

Runtime uses `kpatch kpm load PATH [ARGS]`; a literal `--` is no longer passed as KPM
argument data.

WebUI also passes `-A` data directly through `spawn()` argv instead of shell-quoting
values and accidentally embedding quote/backslash characters. Shell escaping remains
only on actual shell command strings.

### FR-011 — lifecycle event path mismatched packaged ABI — **RESOLVED**

The Public1158 compatibility CLI implements reviewed KPM event command `0x1150` with
an exact event allowlist. `service.sh` dispatches `POST_FS_DATA` and dispatches
`BOOT_COMPLETED` only after Android reports boot completion. Next2026 never receives
the Public event command.

### FR-012 — hidden runtime failures / false hello success — **RESOLVED**

`kpatch hello` fails non-zero on syscall/authentication or foreign magic. Handshake,
exclusion, rehook and Public event failures are surfaced in logs/unresolved state.

### FR-013 — final ZIP reproducibility unproven — **RESOLVED**

`scripts/package_module.sh` normalizes timestamps, strips host-specific ZIP extras,
uses canonical root entry names and a stable lexical file order.

The final assembled module tree is packaged twice and must compare byte-for-byte
identical before artifact upload. This passed in Build run `31233359168`.

## Remaining release blocker

### FR-014 — physical device lifecycle evidence — **OPEN / RELEASE-BLOCKING**

Hosted CI cannot prove that a real device survives and correctly rolls back a boot
partition write. The release gate remains closed until a supported ARM64 device
produces evidence for all of the following:

1. read-only preflight and exact boot slot/target resolution;
2. validated rollback backup creation before mutation;
3. patch + destructive write + exact-range readback verification;
4. cold boot with `sys.boot_completed=1`;
5. `kpatch hello == hello1158` and valid `kpver`;
6. superkey mode `0600` and matching transaction digests;
7. KPM query/list behavior;
8. one controlled diagnostic KPM load → info → unload cycle if a separately reviewed
   diagnostic KPM is supplied;
9. normal reboot and a second successful userspace/kernel handshake;
10. read-only rollback eligibility verification;
11. transaction-bound restore of the exact captured backup;
12. reboot after restore and confirmation that the original boot/root chain is intact;
13. negative rollback tests: device mismatch and externally modified boot must refuse
    automatic restore;
14. evidence bundle tied to the package/source/component hashes used for the test.

`scripts/device_validation.sh` implements the evidence workflow. Read-only phases are
default-safe. The destructive restore and KPM-cycle modes require exact unlock
environment tokens and are never called automatically by CI or module startup.

## Unsupported general baseline

Character/NAND boot targets remain outside the reviewed release baseline. The writer
rejects them until a device-specific erase/write/readback implementation and physical
validation matrix exist.

## Branch policy

Do **not** remove `module/FLASH_REVIEW_BLOCKED`, mark PR #5 ready, merge it, or publish
a release solely because CI is green.

The marker may be removed only on a dedicated physical-validation candidate after the
exact source/artifact identities are frozen. The review/release branch remains blocked
until FR-014 evidence passes.