# Android NDK r29 setup

PatchNest package builds require Android NDK revision exactly:

```text
29.0.14206865
```

The build rejects any other revision by reading `source.properties` before a
compiler is used.

## Preferred installation: Android SDK Manager

Accept the Android SDK licence through the normal Android Studio or SDK Manager
flow, then install the exact side-by-side package:

```sh
sdkmanager "ndk;29.0.14206865"
```

Set `ANDROID_NDK_HOME` to the resulting directory, commonly:

```sh
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/29.0.14206865"
```

Confirm the revision before building:

```sh
grep '^Pkg.Revision' "$ANDROID_NDK_HOME/source.properties"
```

Expected output:

```text
Pkg.Revision = 29.0.14206865
```

The repository does not automate licence acceptance and does not pass `yes` to
`sdkmanager --licenses`.

## Official direct packages

The Android NDK download page publishes these r29 values:

| Platform | Package | Size (bytes) | Official SHA1 |
|---|---|---:|---|
| Windows 64-bit | `android-ndk-r29-windows.zip` | 833850862 | `ab3bb30fbb9e6903666d60c55d11e78b04e07472` |
| macOS | `android-ndk-r29-darwin.dmg` | 1156294030 | `0eecb29cfe791e039740e2a8bcf0af02b7132bd8` |
| Linux x86-64 | `android-ndk-r29-linux.zip` | 783549481 | `87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b` |

Only download after reviewing and accepting the Android SDK licence on the
official Android Developers page.

Linux verification example:

```sh
actual_size=$(stat -c '%s' android-ndk-r29-linux.zip)
[ "$actual_size" = 783549481 ]
printf '%s  %s\n' \
  87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b \
  android-ndk-r29-linux.zip | sha1sum -c -
```

Windows PowerShell verification example:

```powershell
$path = "android-ndk-r29-windows.zip"
if ((Get-Item $path).Length -ne 833850862) { throw "NDK size mismatch" }
$sha1 = (Get-FileHash $path -Algorithm SHA1).Hash.ToLowerInvariant()
if ($sha1 -ne "ab3bb30fbb9e6903666d60c55d11e78b04e07472") {
    throw "NDK SHA1 mismatch"
}
```

The official page currently publishes SHA1 rather than SHA-256 for these NDK
packages. Package name, HTTPS origin, exact byte size, published SHA1, and the
internal `Pkg.Revision` must all match. Prefer SDK Manager because it consumes
Google's signed repository metadata rather than relying only on the displayed
legacy checksum.

## Build

After `ANDROID_NDK_HOME` is set:

```sh
bash build.sh
```

For a publishable candidate, use:

```sh
bash scripts/build_release_candidate.sh
```

The latter currently fails intentionally because the KPM key status remains
`development`.
