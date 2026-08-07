# PatchNest KPM admission audit

Audit date: 2026-08-07

This audit covers KPM package ingestion, persistent storage, boot-time
admission, signature policy, and failure isolation. It does not approve any
historical hiding or policy-bypass prototype for release.

## Confirmed previous defects

### ZIP extraction before reliable path validation

The previous installer checked paths only after extraction and did not enforce
an entry-count, extracted-size, symlink, or rooted source-path policy.

**Current branch:** the installer lists entries before extraction, rejects
absolute/traversal/backslash/colon/control-character names, caps entries at 128,
caps extracted data at 32 MiB, and rejects extracted symbolic links.

### Linux object files treated as KPMs

The previous installer accepted `.ko` and `.o`, then renamed the selected file
to `.kpm`. The boot service also scanned all three extensions.

**Current branch:** installation rejects `.ko/.o`. Early boot moves any legacy
`.ko/.o` files to `kpm/failed` before the broad legacy service loop executes.

### Multi-binary packages silently selected one file

The previous installer used the first file found. Archive ordering could decide
which binary was installed.

**Current branch:** exactly one `.kpm` or a source package is accepted. Multiple
binaries, mixed binary/source packages, and packages without a candidate are
rejected.

### Missing format validation

A file with a `.kpm` extension was not sufficient evidence that it was a
KernelPatch KPM.

**Current branch:** binary and compiled candidates must pass `kptools -l -M`
before entering the installation stage.

### Signature/autoload policy bypass

The installer could save a module with autoload disabled, but `service.sh`
loaded every file under the live KPM directory and ignored `.autoload` markers.
The service also defaulted to a policy that allowed unsigned modules.

**Current branch:**

- a supplied signature must validate or installation fails;
- unsigned modules cannot be loaded immediately and receive no autoload marker;
- before service starts, `.kpm` files without an autoload marker are moved to
  `kpm_quarantine` with their sidecars;
- new installations default to `KPM_SIGNATURE_POLICY=strict`;
- existing explicit user policy is preserved;
- invalid/unsigned autoload modules under strict policy are still rejected by
  the existing service verifier.

### Argument concatenation

The previous immediate-load path constructed `ARGS_OPT="-- $MOD_ARGS"` and
expanded it unquoted. Whitespace changed the argv shape.

**Current branch:** immediate load passes the entire configured argument string
as one argv value after `--`.

### Partial package preparation

The previous installer wrote directly into persistent directories while still
copying metadata and source ZIP files.

**Current branch:** binary, metadata, signature, source ZIP, digest, event, and
argument files are prepared under a per-process staging directory on `/data`.
Persistent metadata is replaced only after preparation; the KPM binary is moved
last. Concurrent installations are blocked by a lock directory.

## Compatibility consequences

The safer behavior is intentionally stricter:

- unsigned KPMs can be retained for review but are quarantined before boot-time
  loading;
- a signed module with `autoLoad=false` is also quarantined rather than loaded
  by the legacy broad service loop;
- devices without a usable `unzip -Z1`, `du -sk`, `sha256sum`, or `kptools`
  cannot install a KPM through this path;
- source builds remain dependent on the separately audited compiler pipeline;
- a user who previously selected `KPM_SIGNATURE_POLICY=off` keeps that explicit
  setting, but modules without autoload markers are still quarantined.

## Remaining blockers

1. The embedded Ed25519 deployment key and signing ceremony require an
   independent provenance review; the private key must remain out of repository
   and device packages.
2. Signature verification must be exercised on real Android OpenSSL variants.
3. The WebUI patch page currently shell-quotes KPM `-A` values even though it
   uses an argv-based `spawn()` call. This can add literal quote/backslash
   characters. Fix it in a dedicated WebUI change rather than rewriting the
   full page together with boot scripts.
4. Quarantine management needs an explicit WebUI surface before users can
   review, delete, or deliberately re-admit a disabled module.
5. The retained ZIP digest file currently proves bytes but should be normalized
   to reference the final installed ZIP filename rather than a staging path.
6. No load/control/unload/reboot lifecycle has been performed on a physical
   device for this branch.

## Release decision

KPM installation and boot admission are **not release-ready**. The branch adds
fail-closed source behavior and offline contracts, but physical signature,
quarantine, lifecycle, and rollback evidence is still required.
