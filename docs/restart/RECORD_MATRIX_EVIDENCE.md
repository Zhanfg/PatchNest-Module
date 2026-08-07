# Recording PatchNest physical-test evidence

Completed device matrices must stay outside the Git worktree. The tracked
`device-matrix/*.yaml` files remain Pending templates because committing a
`testedCommit=HEAD` value would create a new HEAD and invalidate the record.

## Prepare an external matrix directory

```sh
commit=$(git rev-parse HEAD)
mkdir -p "/secure/patchnest-evidence/$commit/matrices"
cp device-matrix/*.yaml "/secure/patchnest-evidence/$commit/matrices/"
```

Build or select the exact candidate three-file set:

```text
out/PatchNest-Module.zip
out/PatchNest-Module.zip.sha256
out/build-provenance.json
```

## Preview one record

The recorder is preview-only unless `--write` is supplied:

```sh
python3 scripts/record_matrix_evidence.py \
  --matrix-dir "/secure/patchnest-evidence/$commit/matrices" \
  --case-id AB-01 \
  --candidate out/PatchNest-Module.zip \
  --evidence-archive /secure/evidence/AB-01-session.tar.gz \
  --evidence-label evidence/AB-01-session.tar.gz \
  --runtime-compat-report /secure/evidence/runtime-compat.json \
  --rom-fingerprint-file /secure/evidence/rom-fingerprint.txt \
  --session-id op13-slot-a-session-01 \
  --device-alias op13-test-01 \
  --soc-family qcom-sm8750 \
  --root-manager apatch \
  --active-slot a \
  --kernel-release 6.6.89-android15
```

The command verifies candidate digest/provenance, hashes all three evidence
inputs, checks slot/root-manager semantics, and prints the exact record without
modifying a matrix.

## Write atomically

After reviewing the preview, append `--write`. Existing passing rows require
`--replace` to prevent accidental evidence replacement.

The write uses a process-unique temporary file, flushes and `fsync`s it,
preserves the matrix mode, atomically replaces the target, and `fsync`s the
parent directory. Matrix, candidate, digest, provenance, and evidence symlinks
are rejected.

Each record includes:

- evidence archive path and SHA-256;
- exact tested commit;
- exact candidate ZIP SHA-256;
- session/device/SoC/root-manager/slot labels;
- ROM fingerprint SHA-256;
- kernel release;
- strict runtime compatibility report SHA-256;
- timezone-aware timestamp.

Use anonymous aliases only. Never place serial numbers, IMEI, Android ID,
account names, or raw build fingerprints in the matrix.

## Validate the completed set

```sh
bash scripts/run_evidence_gate_checks.sh \
  out/PatchNest-Module.zip \
  "/secure/patchnest-evidence/$commit/matrices"
```

This runs the complete release-ready gate and then independently confirms that
every passing evidence record binds the selected candidate digest.

The current repository still uses a development signing key and tracked matrix
templates remain Pending, so publication must remain blocked.
