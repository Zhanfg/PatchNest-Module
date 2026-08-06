# PatchNest Module

**English** | [中文](README_zh-CN.md)

PatchNest Module provides a KPM host and management WebUI for Magisk, KernelSU, KernelSU-Next and APatch. It is maintained as a downstream project of `KernelSU-Next/KPatch-Next-Module` with an independent release and dependency chain.

## Repository architecture

| Repository | Responsibility |
|---|---|
| [`Zhanfg/PatchNest-Module`](https://github.com/Zhanfg/PatchNest-Module) | Module installer, WebUI, package and update entry point |
| [`Zhanfg/KernelPatch-Public`](https://github.com/Zhanfg/KernelPatch-Public) | Source and releases for `kpimg` and `kptools` |
| [`Zhanfg/PatchNest`](https://github.com/Zhanfg/PatchNest) | Source/release location for the `kpatch` user-space tool |
| [`Zhanfg/PatchNest-Kpms`](https://github.com/Zhanfg/PatchNest-Kpms) | KPM source and catalog |

## KPM repository

The default catalog is:

```text
https://raw.githubusercontent.com/Zhanfg/PatchNest-Kpms/main/kpm_repo.json
```

The WebUI also accepts additional HTTPS catalog URLs. A system-wide catalog override can be placed at:

```text
/data/adb/patchnest/repos.json
```

Catalog source, build and release work is maintained in `PatchNest-Kpms`; KPM binaries are not built into the PatchNest Module archive.

## Build integrity

Dependency versions and trusted release digests are pinned in `version.properties`. Both local and CI builds reject missing or mismatched SHA256 values. Release tags use the form `v<internal-version>`, while `module.prop` and `update.json` use the version without the `v` prefix.

The current restart baseline and remaining work are recorded in [`docs/restart/BASELINE.md`](docs/restart/BASELINE.md).

## Credits

- Upstream module: [`KernelSU-Next/KPatch-Next-Module`](https://github.com/KernelSU-Next/KPatch-Next-Module)
- Patch scripts derived from [`bmax121/APatch`](https://github.com/bmax121/APatch)
- `magiskboot` from [`topjohnwu/Magisk`](https://github.com/topjohnwu/Magisk)

## License

- PatchNest-Module: [GPL-3.0](LICENSE)
- PatchNest/KernelPatch components retain their applicable upstream GPL licenses.
- WebUI: [MIT](webui/LICENSE)
