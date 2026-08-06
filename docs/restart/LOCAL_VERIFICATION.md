# PatchNest local verification without GitHub Actions

The branch `restart/offline-audit-suite` is designed to be reviewed and tested
without consuming GitHub Actions minutes.

## Host requirements

Recommended host: Linux x86-64 with:

- Bash
- Python 3.11+
- OpenSSL with Ed25519 `pkeyutl -rawin`
- Node.js and pnpm for WebUI tests
- standard GNU coreutils

The core source checks do not require network, Android root, a boot image, or an
attached device.

## One-command source checks

From a complete checkout:

```sh
bash scripts/run_offline_checks.sh
```

This performs:

1. Python syntax compilation;
2. offline scanner unit tests;
3. boot hardening contracts;
4. install/uninstall/KPM lifecycle contracts;
5. the no-on-device-source-build policy;
6. kptools argv compatibility vectors;
7. Ed25519 valid/tampered/malformed vectors;
8. release metadata consistency tests;
9. generation of JSON and Markdown audit reports;
10. Bash syntax parsing of shell entry points.

Reports are written to `audit-output/`, which is ignored by Git.

## WebUI checks

After dependencies are installed from the committed lockfile:

```sh
cd webui
pnpm install --frozen-lockfile
pnpm test --run
pnpm build --emptyOutDir
```

Relevant new tests include:

- `ksu-profile-target.test.js`
- `module-config-validation.test.js`

The tests validate inputs before any root bridge call. They do not invoke a real
KernelSU manager.

## Reproducible package build

A package build downloads immutable release assets and therefore needs network,
but it does not require Actions:

```sh
bash build.sh
```

Expected outputs:

```text
out/PatchNest-Module.zip
out/PatchNest-Module.zip.sha256
out/build-provenance.json
```

Run twice from the same commit and `SOURCE_DATE_EPOCH`; the archive hashes must
match. Do not update `update.json` until the candidate ZIP has completed the
physical-device matrix.

## Optional local release-asset check

```sh
python3 scripts/verify_release_metadata.py \
  --release-asset out/PatchNest-Module.zip
```

This intentionally fails when `update.json` still describes an older published
asset. That failure is correct until a reviewed release candidate is frozen.

## Android read-only evidence

Copy `scripts/collect_device_evidence.sh` to the device and run as root:

```sh
sh collect_device_evidence.sh
```

The default does not read the complete boot partition. To calculate a read-only
active boot SHA-256:

```sh
sh collect_device_evidence.sh --hash-boot
```

Review the sharing notice and logs before uploading the resulting archive.
Device identifiers can appear in properties and kernel logs.

## What has actually been executed during this review

The isolated analysis environment could not resolve GitHub DNS, so the full
branch could not be cloned there. The following focused vectors were executed
independently:

- the repository Ed25519 public probe vector verified successfully with RFC
  8410 DER wrapping and `openssl pkeyutl -verify -pubin -keyform DER -rawin`;
- the kptools argv rotation/decoding logic preserved ordinary argument order,
  decoded WebUI `-A` quoting, and rejected missing, mismatched, control-bearing,
  and oversized values.

The complete checkout command above remains mandatory. Static review and focused
vectors are not a substitute for running the full suite or the physical-device
matrix.
