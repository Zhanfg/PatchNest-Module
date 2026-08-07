# PatchNest release gate

A green build is not sufficient for a boot-modifying module. The following
gates are cumulative and non-negotiable.

## Gate 0 — repository integrity

- No device logs, boot images, private keys, superkeys, tokens, or personal
  archives are committed.
- Every downloaded build input is pinned by immutable version/commit and
  SHA-256.
- Existing release tags are not overwritten.
- Source version, module version, update metadata, archive name, and Git tag
  agree.
- The KPM public key, source literal, raw-key SHA-256 fingerprint, and status
  agree under `scripts/verify_signing_key_policy.py`.

## Gate 1 — offline source verification

Required command:

```sh
bash scripts/run_offline_checks.sh
```

With a prepared dependency tree, also run:

```sh
bash scripts/run_webui_offline_checks.sh
```

All failures must be understood. No blocker may be waived by changing its
severity or adding a broad ignore pattern.

## Gate 2 — verifier and supply-chain verification

The package must contain its own static AArch64 Ed25519 verifier. Android system
OpenSSL is not an accepted runtime dependency.

Required properties:

- Monocypher version, release asset SHA-256, and tag commit are pinned;
- Android NDK revision is exactly `29.0.14206865`;
- the host verifier accepts the valid deployment-key vector and rejects the
  tampered-message vector before cross-compilation;
- `bin/kpm-verify` is AArch64 and has no dynamic interpreter;
- `licenses/Monocypher-LICENCE.md` is packaged;
- build provenance records the Monocypher version/commit, NDK revision, and
  verifier backend;
- the build runs from a clean Git tree.

Before a public Release, run:

```sh
python3 scripts/verify_signing_key_policy.py --release-ready
```

This command must fail while `kpm_signing_key_status=development`. A production
key requires the custody, independent verification, rotation, and on-device
validation evidence defined in `KPM_SIGNING_KEY_POLICY.md`.

## Gate 3 — reproducible package verification

- Build from a clean checkout with the pinned NDK.
- Record source commit and package SHA-256.
- Build twice with the same commit and `SOURCE_DATE_EPOCH`.
- Require byte-identical ZIP, `.sha256`, and provenance output.
- Verify all bundled executable hashes against the pinned manifest.
- Reject placeholder hashes and mutable download URLs.
- Confirm the package contains no temporary work files or generated evidence.
- Confirm update JSON still points to the previously published immutable asset
  until the reviewed candidate is explicitly released.

## Gate 4 — file-only boot-image round trip

Using redistributable test fixtures or user-owned images:

1. unpack stock image;
2. verify non-empty kernel;
3. patch with flashing disabled;
4. reopen output and verify `patched=true`;
5. unpatch the generated image;
6. reopen output and verify `patched=true` is absent;
7. compare boot header/component inventory before and after;
8. repeat with malformed KPM, missing kpimg, invalid arguments, interrupted
   work directory, and insufficient output storage.

No physical block device is involved in this gate.

## Gate 5 — Android runtime compatibility

From the exact installed candidate, run:

```sh
su -c 'sh /data/adb/modules/PatchNest/runtime_compat_check.sh --strict'
```

The report must show a passing packaged `ed25519_verifier`, boot target mapping,
required shell/coreutils behavior, and blockdev option support. The compatibility
probe itself must not execute `blockdev --setrw` or write any block device.

Every `flash_image()` call repeats this strict read-only gate immediately before
`blockdev --setrw` and `dd`. Gate failure code 8 means no write was attempted.

## Gate 6 — physical write and rollback

At minimum:

- one A/B device, both active-slot states;
- one non-A/B device;
- two SoC families;
- patch, reboot, normal unpatch, reboot;
- verified backup restore;
- failed-write/readback injection;
- documented manual rollback from bootloader/recovery.

Every direct write must record source and readback SHA-256. A successful `dd`
exit status without readback equality is a failure. Each session must attach the
read-only evidence archive containing the strict runtime-compatibility report.

## Gate 7 — KPM lifecycle

Start with the build-only diagnostic KPM. Verify:

- metadata parsing;
- signature verification through the packaged backend;
- embedding;
- load;
- control response;
- unload;
- configured reboot event;
- failure quarantine;
- no boot regression.

Historical prototype modules remain outside the installable catalog until each
is independently ported, reviewed, signed, and tested.

## Gate 8 — WebUI behavior

- Patch and unpatch actions show the exact target partition.
- Normal unpatch is not described as backup restoration.
- Backup restore displays only a target-bound, digest-verified backup.
- Confirmation cannot proceed when backup verification fails.
- Root bridge commands use argument arrays or explicit shell escaping.
- Remote strings, logs, manifests, and catalog fields do not enter HTML sinks
  without escaping.
- Process exit, stderr, compatibility-gate, and readback failures are shown to
  the user.

## Gate 9 — release candidate freeze

After physical testing starts:

- freeze the candidate commit;
- allow documentation/evidence additions only;
- any source, script, binary, dependency, linker, key, or packaging change
  resets affected tests;
- attach a completed device matrix to the release PR;
- do not publish automatically from an unreviewed push.

## Gate 10 — release and rollback package

A release must include:

- module archive and SHA-256;
- source commit;
- dependency and verifier provenance;
- production signing-key public fingerprint;
- supported/unsupported device statement;
- known limitations;
- explicit backup and rollback instructions;
- evidence that the rollback path was exercised on the release candidate;
- no claim of automatic recovery unless an early-boot executor actually
  performed and verified the restore.
