# Android runtime compatibility probe

`module/runtime_compat_check.sh` is a read-only device-side probe for the shell
and command features used by PatchNest. It does not patch, unpatch, restore, set
a block device writable, or write to a boot partition.

## Run

Print the report only:

```sh
su -c 'sh /data/adb/modules/PatchNest/runtime_compat_check.sh --stdout'
```

Persist a TSV report under `/data/adb/patchnest/diagnostics/`:

```sh
su -c 'sh /data/adb/modules/PatchNest/runtime_compat_check.sh --write'
```

Fail when a required capability is missing:

```sh
su -c 'sh /data/adb/modules/PatchNest/runtime_compat_check.sh --strict'
```

## Packaged Ed25519 backend

PatchNest packages a static AArch64 `bin/kpm-verify` executable. It is built
from the minimal read-only wrapper in `module/tools/kpm-verify.c` and the pinned
Monocypher 4.0.3 Ed25519 implementation using Android NDK revision
`29.0.14206865`.

Android system OpenSSL is not required and is not accepted as the normal runtime
backend. `module/kpm_verify.sh` self-tests the packaged binary against the
configured public-key vector and fails closed when the binary is missing,
symlinked, non-executable, or rejects the vector. OpenSSL exists only as an
explicit host-test fallback.

The build verifies the official Monocypher release asset SHA-256, checks the
pinned tag commit, runs valid and tampered-message host vectors, cross-compiles a
static AArch64 PIE, rejects a dynamic interpreter, packages the upstream licence,
and records the verifier supply chain in `build-provenance.json`.

## Checked capabilities

The probe exercises:

- `/system/bin/sh` and arm64 ABI detection;
- packaged `kpatch`, `kptools`, `kpimg`, `magiskboot`, `kpm-verify`, and
  `kp-safemode` executability;
- `mktemp -d` template behavior;
- `stat -c`, `readlink -f`, and `du -sk`;
- `sha256sum` and `sha256sum -c`;
- `unzip -Z1` against an embedded minimal ZIP fixture;
- `dd iflag=fullblock conv=notrunc,fsync` against a temporary regular file;
- the packaged Ed25519 verifier deployment-key self-test;
- `blockdev --getsize64`, `--getbsz`, `--getro`, and advertised `--setrw`
  support;
- boot-only target discovery plus sysfs/by-name logical partition mapping.

`blockdev --setrw` is deliberately **not executed**. The probe only confirms
that the option is advertised. Actual writable-state and flash/readback behavior
remain part of the physical-device validation matrix.

## Pre-write enforcement

`flash_image()` repeats the strict compatibility probe immediately before a
direct block write. It runs before `blockdev --setrw` and before `dd`. When the
probe fails, `flash_image()` returns error code 8 and states that no block write
was attempted.

## Output

The TSV columns are:

```text
check_id    status    required    detail
```

A `fail` row with `required=yes` blocks a flash candidate. A `warn` row is a
non-fatal limitation or an intentionally skipped host-only check.

This report is diagnostic evidence only. A passing report does not replace A/B
and non-A/B patch, reboot, unpatch, exact-backup restore, failed-write, and
rollback testing on physical devices.
