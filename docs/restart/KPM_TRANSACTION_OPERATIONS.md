# KPM transaction operations

PatchNest stores KPM admission and runtime failures as transaction directories,
not as isolated primary files. A transaction may contain:

- `module.kpm`, `module.ko`, or `module.o`;
- `module.kpm.sig`;
- `events`, `args`, and `autoload` sidecars;
- `manifest.properties`;
- `checksums.sha256`;
- `state`.

The two persistent scopes have different semantics:

| Scope | Directory | Purpose | Activation |
|---|---|---|---|
| quarantine | `/data/adb/patchnest/kpm_quarantine` | KPM was not admitted, commonly because autoload was disabled or policy could not be established | May be activated only after full checksum, parser, and Ed25519 verification |
| failed | `/data/adb/patchnest/kpm_failed` | Linux object, strict unsigned KPM, invalid signature, malformed runtime arguments, or KPM load failure | Read-only evidence; activation is prohibited |

## Read-only listing

Backward-compatible quarantine listing:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh list
```

Explicit scopes:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh list quarantine
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh list failed
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh list all
```

The first output column is `scope`. Integrity failures and incomplete entries
remain visible but are not treated as valid transactions.

## Read-only inspection

Backward-compatible quarantine inspection:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh inspect <entry-id>
```

Explicit inspection:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh inspect quarantine <entry-id>
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh inspect failed <entry-id>
```

Inspection prints the scope, checksum status, manifest fields, file sizes, and
per-file SHA-256 values. It never loads a KPM or changes persistent state.

## Quarantine activation

Only quarantine transactions can be activated:

```sh
sh /data/adb/modules/PatchNest/manage_kpm_quarantine.sh activate <entry-id>
```

Activation performs all of the following before persistence changes:

1. resolves the entry from the hard-coded quarantine root;
2. verifies the original transaction checksum set;
3. copies the complete transaction to a private staging directory;
4. verifies the copied transaction again;
5. requires `primary=module.kpm`;
6. validates optional event and argument sidecars;
7. requires `kptools` to parse the KPM;
8. requires a valid Ed25519 signature;
9. refuses every existing live destination;
10. commits signature and sidecars before the KPM binary;
11. creates autoload only after the commit succeeds;
12. removes partial live files if commit fails.

Activation never hot-loads the module. Reboot is required so the normal early
admission and late service paths remain authoritative.

Failed transactions cannot be activated through a scope argument, alias, force
flag, or alternate command. There is no delete command in the manager.

## Rollback-failed transactions

The shared transaction store normally restores the primary file and all
sidecars if manifest or checksum creation fails. If an external conflict makes
restoration impossible, the transaction directory is retained with:

```text
state=rollback-failed
```

Do not delete this directory automatically. It may contain the only surviving
original KPM or sidecar. Review the transaction log and compare the live paths
before manual recovery.

## Durable KPM installation

Persistent KPM package installation uses a separate journal under:

```text
/data/adb/patchnest/.kpm-stage.<pid>/journal.properties
```

Journal phases are:

- `preparing`: no persistent destination changed;
- `backup`: existing destinations are being moved into `previous/`;
- `writing`: new destinations may be partially present;
- `complete`: the new persistent set is authoritative.

The next installer invocation recovers abandoned stages before taking the lock:

- `preparing` is discarded;
- `backup` restores moved old files without deleting untouched destinations;
- `writing` removes partial new destinations and restores the complete old set;
- `complete` keeps the committed new set and removes stale staging.

A recent lock with missing or uncertain owner metadata is treated as active for
a bounded grace period. A numeric owner PID that definitely no longer exists is
recoverable immediately.

## Offline verification

From a complete checkout:

```sh
bash scripts/run_transaction_offline_checks.sh
```

This entry point requires no network, Actions runner, Android device, or root
permission. It runs shell parsing, static contracts, transaction rollback
vectors, scoped visibility contracts, and durable installation recovery vectors.

These host tests do not replace Android shell/tool compatibility checks or the
physical-device validation matrix.
