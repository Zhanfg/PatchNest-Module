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

## Gate 1 — offline source verification

Required commands:

```sh
python3 tests/test_offline_audit.py
python3 tests/validate_boot_hardening.py
python3 scripts/offline_audit.py --no-syntax
```

Where available, also run:

```sh
bash -n module/patch/*.sh module/*.sh scripts/*.sh
node --check webui/*.js webui/page/*.js webui/test/*.js
```

All failures must be understood. No blocker may be waived by changing its
severity or adding a broad ignore pattern.

## Gate 2 — reproducible package verification

- Package from a clean checkout.
- Record source commit and package SHA-256.
- Verify all bundled executable hashes against the pinned manifest.
- Reject placeholder hashes and mutable download URLs.
- Confirm the package contains no temporary work files or generated evidence.
- Confirm update JSON points to an existing immutable release asset.

## Gate 3 — file-only boot-image round trip

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

## Gate 4 — physical write and rollback

At minimum:

- one A/B device, both active-slot states;
- one non-A/B device;
- two SoC families;
- patch, reboot, normal unpatch, reboot;
- verified backup restore;
- failed-write/readback injection;
- documented manual rollback from bootloader/recovery.

Every direct write must record source and readback SHA-256. A successful `dd`
exit status without readback equality is a failure.

## Gate 5 — KPM lifecycle

Start with the build-only diagnostic KPM. Verify:

- metadata parsing;
- embedding;
- load;
- control response;
- unload;
- configured reboot event;
- failure quarantine;
- no boot regression.

Historical prototype modules remain outside the installable catalog until each
is independently ported, reviewed, and tested.

## Gate 6 — WebUI behavior

- Patch and unpatch actions show the exact target partition.
- Normal unpatch is not described as backup restoration.
- Backup restore displays only a target-bound, digest-verified backup.
- Confirmation cannot proceed when backup verification fails.
- Root bridge commands use argument arrays or explicit shell escaping.
- Remote strings, logs, manifests, and catalog fields do not enter HTML sinks
  without escaping.
- Process exit, stderr, and readback failures are shown to the user.

## Gate 7 — release candidate freeze

After physical testing starts:

- freeze the candidate commit;
- allow documentation/evidence additions only;
- any source, script, binary, dependency, linker, or packaging change resets
  affected tests;
- attach a completed device matrix to the release PR;
- do not publish automatically from an unreviewed push.

## Gate 8 — release and rollback package

A release must include:

- module archive and SHA-256;
- source commit;
- dependency provenance;
- supported/unsupported device statement;
- known limitations;
- explicit backup and rollback instructions;
- evidence that the rollback path was exercised on the release candidate;
- no claim of automatic recovery unless an early-boot executor actually
  performed and verified the restore.
