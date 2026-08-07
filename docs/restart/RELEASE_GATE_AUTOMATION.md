# PatchNest machine-enforced release gate

The repository contains a local release gate under `release_gate/`. It does not
use GitHub Actions and does not write an Android block device.

## Structure mode

Run after source changes:

```sh
bash scripts/run_release_gate_checks.sh
```

Structure mode validates:

- clean Git provenance;
- signing-key and Monocypher metadata consistency;
- absence of tracked private-key material;
- the four tracked machine-readable matrix templates;
- source module layout;
- source Git file modes and writable-file boundaries.

The tracked templates intentionally remain `pending`. Passing structure mode
does **not** mean the module is safe to flash or publish.

## Why completed matrices are external

A completed row must contain the exact tested commit in `testedCommit`. Writing
that commit into a tracked matrix and committing the change would create a new
commit, immediately invalidating the recorded value. Therefore:

- `device-matrix/*.yaml` in Git are immutable Pending templates;
- completed matrices are copied to a controlled directory outside the worktree;
- release-ready mode accepts them only through `--matrix-dir`;
- the external records bind to the candidate provenance `sourceCommit` and the
  current clean `HEAD`.

Example preparation:

```sh
commit=$(git rev-parse HEAD)
mkdir -p "/secure/patchnest-evidence/$commit/matrices"
cp device-matrix/*.yaml "/secure/patchnest-evidence/$commit/matrices/"
```

Edit only the external copies as physical tests are completed.

## Release-ready mode

After building an exact candidate from a clean frozen commit, run:

```sh
bash scripts/run_release_gate_checks.sh \
  --release-ready \
  --candidate out/PatchNest-Module.zip \
  --matrix-dir "/secure/patchnest-evidence/$(git rev-parse HEAD)/matrices"
```

Release-ready mode requires:

- a non-shallow clean checkout;
- a production signing key accepted by the key-policy verifier;
- a candidate ZIP, exact sibling `.sha256`, and `build-provenance.json` bound to
  the current commit;
- a static ELF64 little-endian AArch64 `bin/kpm-verify` without `PT_INTERP`;
- no duplicate, traversal, symlink, temporary, build-only, writable, or
  private-key-like archive entries;
- all 46 required external matrix cases marked `pass`;
- each passing case bound to the same 40-character source commit;
- each evidence record bound to an anonymous session/device identity, SoC,
  root manager, active slot, ROM fingerprint digest, kernel release, strict
  runtime-compatibility report digest, archive digest, and timezone timestamp;
- A/B coverage across at least two device aliases, two SoC families, and active
  slots `a` and `b`;
- non-A/B evidence with `activeSlot=none`;
- global evidence coverage for Magisk, KernelSU Next, and APatch.

Any source change invalidates the candidate provenance and all matrix
`testedCommit` values until the package and affected physical tests are repeated.

## Matrix files

The files are JSON documents with a `.yaml` suffix. JSON is a strict subset of
YAML 1.2, so the checks use Python's standard library without adding PyYAML as a
supply-chain dependency.

```text
device-matrix/
├── ab_device.yaml
├── non_ab_device.yaml
├── avb_cases.yaml
└── recovery_cases.yaml
```

There are 47 cases: 46 required and one optional MediaTek naming case.

## Recording a passing row

```json
{
  "id": "AB-01",
  "title": "Patch active slot A and verify exact-length readback",
  "required": true,
  "status": "pass",
  "testedCommit": "0123456789abcdef0123456789abcdef01234567",
  "evidence": [
    {
      "path": "evidence/AB-01-op13-a-20260807.tar.gz",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "recordedAt": "2026-08-07T03:00:00Z",
      "sessionId": "op13-slot-a-session-01",
      "deviceAlias": "op13-test-01",
      "socFamily": "qcom-sm8750",
      "rootManager": "apatch",
      "activeSlot": "a",
      "romFingerprintSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "kernelRelease": "6.6.89-android15",
      "runtimeCompatSha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  ]
}
```

`deviceAlias` and `sessionId` must be anonymous labels, never a serial number,
IMEI, Android ID, account name, or other public identifier. Hash the complete
ROM build fingerprint before recording it. `runtimeCompatSha256` is the digest
of the strict read-only compatibility report from the same boot session.

Allowed statuses:

- `pending` — not executed;
- `pass` — executed on the stated commit with complete evidence;
- `fail` — executed and failed;
- `blocked` — cannot currently be executed;
- `not-applicable` — only for `required: false`.

Non-passing rows must leave `testedCommit` and `evidence` empty.

## Candidate build wrapper

The publishable candidate entry point requires the external matrix directory:

```sh
PATCHNEST_MATRIX_DIR="/secure/patchnest-evidence/$(git rev-parse HEAD)/matrices" \
  bash scripts/build_release_candidate.sh
```

The production-key policy is checked before any build/network work. After the
build, the wrapper runs the complete release-ready gate against the exact ZIP,
digest, provenance, and external matrices.

## Individual checks

```sh
python3 release_gate/check_git_clean.py --root .
python3 release_gate/check_signature.py --root .
python3 release_gate/check_boot_matrix.py --root .
python3 release_gate/check_module_layout.py --root .
python3 release_gate/check_permissions.py --root .
```

Add `--json` for machine-readable output. The matrix checker accepts
`--matrix-dir`; candidate-aware checks accept `--candidate`.

## Current state

The tracked templates remain Pending and the signing key remains development.
Structure mode can pass, while release-ready mode must fail. Do not weaken these
conditions to produce a release.
