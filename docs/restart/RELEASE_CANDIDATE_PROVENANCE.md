# PatchNest release-candidate provenance

A PatchNest release candidate is a three-file set produced from one clean,
non-shallow commit:

```text
out/PatchNest-Module.zip
out/PatchNest-Module.zip.sha256
out/build-provenance.json
```

A ZIP by itself is not a release candidate.

## Required validation

Completed device matrices must be stored outside the Git worktree. The release
wrapper therefore requires an explicit evidence directory:

```sh
PATCHNEST_MATRIX_DIR="/secure/patchnest-evidence/$(git rev-parse HEAD)/matrices" \
  bash scripts/build_release_candidate.sh
```

After `build.sh` finishes, the wrapper invokes the complete evidence gate:

```sh
bash scripts/run_evidence_gate_checks.sh \
  out/PatchNest-Module.zip \
  "$PATCHNEST_MATRIX_DIR"
```

This runs the base release gates and then verifies that every passing physical
test record is bound to the exact candidate ZIP SHA-256. Calling only
`run_release_gate_checks.sh` is insufficient for a publishable candidate.

The signature/provenance gate derives the sibling digest and provenance paths
from the selected ZIP. Renaming or moving only one file breaks the candidate
set.

## Digest file

`PatchNest-Module.zip.sha256` must contain exactly one line:

```text
<64 lowercase hexadecimal characters><two spaces>PatchNest-Module.zip
```

The digest is recalculated from the selected archive. Additional lines,
absolute paths, alternate filenames, uppercase digests, or a mismatch are
rejected.

## Provenance file

`build-provenance.json` must use schema version 2 and match the selected archive
and current Git checkout:

- `sourceCommit` equals the complete current `HEAD` SHA;
- `sourceTreeStatus` is `clean`;
- `archive` equals `PatchNest-Module.zip`;
- `archiveSha256` equals the recalculated archive digest;
- `archiveSize` equals the archive byte length;
- `kpmSigningPublicKey` matches `version.properties`;
- `kpmSigningKeyFingerprintSha256` matches `version.properties` and is a valid
  lowercase SHA-256 value;
- `kpmSigningKeyStatus` matches `version.properties` and is `production`.

The signing-key policy and Monocypher pin checks run before these comparisons. A
hand-edited provenance file cannot turn a development-key build into a
production candidate.

## External physical evidence binding

The tracked `device-matrix/*.yaml` files are Pending templates. Completed
matrices are external because committing `testedCommit=HEAD` would create a new
HEAD and invalidate the value.

Release-ready mode requires all 46 required external cases to pass on the same
commit as `build-provenance.json.sourceCommit`. It also enforces:

- exact evidence-archive SHA-256 and path binding;
- `candidateSha256` equal to the selected release-candidate ZIP digest;
- anonymous device/session identity;
- ROM fingerprint and strict runtime-compatibility report digests;
- A/B device, SoC, and slot diversity;
- non-A/B `activeSlot=none` semantics;
- Magisk, KernelSU Next, and APatch coverage.

Use `scripts/record_matrix_evidence.py` to calculate these digests. It previews
by default and only atomically modifies an external matrix when `--write` is
supplied.

A source change after testing changes `HEAD`, invalidating the candidate
provenance and matrix `testedCommit` values until both the package and affected
physical tests are repeated. Rebuilding the ZIP also changes `candidateSha256`
and invalidates evidence collected against the previous package.

## Current state

The repository remains on a development signing key and all tracked matrix
cases are pending. `scripts/build_release_candidate.sh` must therefore fail
before publishing. This is intentional.
