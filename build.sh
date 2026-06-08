#!/bin/bash
# P0-3 security fix: enable strict error handling.
# Combined with `curl -fsSL` (also added in download_assets), this prevents
# silent failures (e.g. 0-byte binaries shipping to end users).
set -euo pipefail

if [[ "${1:-}" == "clean" ]]; then
    rm -rf out module/bin module/webroot
    exit 0
fi

mkdir -p out module/bin module/webroot

# Build WebUI
cd webui
pnpm build || { pnpm install && pnpm build; }
cd ..

# Read versions from version.properties
get_ver() {
    [ -f version.properties ] && grep "^$1[[:space:]]*=" version.properties | cut -d'=' -f2 | xargs | sed 's/^"//;s/"$//'
}

download_assets() {
    local repo="$1"
    local tag="$2"
    local outdir="$3"
    shift 3
    local patterns=("$@")

    local url="https://api.github.com/repos/$repo/releases"
    if [[ "$tag" == "latest" ]]; then
        url="$url/latest"
    else
        url="$url/tags/$tag"
    fi

    # P0-3 fix: -f fails on HTTP errors, -s silent, -L follow redirects,
    # combined with set -e the script aborts if GitHub returns 4xx/5xx.
    local release_json
    release_json=$(curl -fsSL "$url")

    for pattern in "${patterns[@]}"; do
        local regex="${pattern//\*/.*}"
        local asset_data
        asset_data=$(echo "$release_json" | jq -r ".assets[] | select(.name | test(\"$regex\")) | .name + \"\t\" + .browser_download_url" | head -n 1)
        if [[ -z "$asset_data" ]]; then
            echo "ERROR: Could not find asset matching $pattern in $repo $tag" >&2
            continue
        fi
        local asset_name=$(echo "$asset_data" | cut -f1)
        local download_url=$(echo "$asset_data" | cut -f2)
        echo "Downloading $asset_name from $download_url"
        curl -fsSL "$download_url" -o "$outdir/$asset_name"

        # P0-10 security fix: verify SHA256 of every downloaded root-level
        # binary against the value pinned in version.properties. This blocks
        # a compromised upstream or MITM from substituting a malicious
        # kernel-level binary.
        # Expected key: e.g. kpimg_linux_v0.13.3
        local key="${asset_name//[-.]/_}_${tag}"
        local expected
        expected=$(get_ver "$key" || true)
        if [[ -n "$expected" ]]; then
            echo "$expected  $outdir/$asset_name" | sha256sum -c - \
                || { echo "ERROR: SHA256 mismatch for $asset_name — refusing to ship unsigned root-level binary" >&2; exit 1; }
        else
            echo "WARNING: no pinned sha256 for $key in version.properties; skipping verification" >&2
        fi
    done
}

VERSION_KERNELPATCH=$(get_ver "kernelpatch")
VERSION_KERNELPATCH="${VERSION_KERNELPATCH:-latest}"
VERSION_PATCHNEST=$(get_ver "patchnest")
VERSION_PATCHNEST="${VERSION_PATCHNEST:-latest}"
VERSION_MAGISKBOOT=$(get_ver "magiskboot")
VERSION_MAGISKBOOT="${VERSION_MAGISKBOOT:-latest}"

# Fetch KernelPatch binaries (kpimg, kptools) from public fork
if [[ ! -f "module/bin/kpimg" || ! -f "module/bin/kptools" ]]; then
    download_assets "Zhanfg/KernelPatch-Public" "$VERSION_KERNELPATCH" "module/bin" "kpimg-linux" "kptools-android"
    mv module/bin/kpimg-linux module/bin/kpimg
    mv module/bin/kptools-android module/bin/kptools
fi

# Fetch kpatch user-space tool from PatchNest
# (kpuser binary only available from PatchNest, not KernelPatch)
if [[ ! -f "module/bin/kpatch" ]]; then
    download_assets "Zhanfg/PatchNest" "$VERSION_PATCHNEST" "module/bin" "kpatch-android"
    mv module/bin/kpatch-android module/bin/kpatch
fi

# Fetch magiskboot
if [[ ! -f "module/bin/magiskboot" ]]; then
    download_assets "topjohnwu/Magisk" "$VERSION_MAGISKBOOT" "module/bin" "Magisk*.apk"

    # Use glob expansion directly instead of ls (avoids issues with
    # filenames containing spaces/newlines and gives a clear error on
    # no match).
    APK=$(printf '%s\n' module/bin/Magisk*.apk 2>/dev/null | head -n 1)
    # P0-3 fix: ensure the APK actually exists before unzipping, and fail
    # loudly if libmagiskboot.so is missing from the APK (path has changed
    # historically).
    if [[ ! -f "$APK" ]]; then
        echo "ERROR: no Magisk APK downloaded" >&2; exit 1
    fi
    if ! unzip -p "$APK" 'lib/arm64-v8a/libmagiskboot.so' > "module/bin/magiskboot" 2>/dev/null; then
        echo "ERROR: lib/arm64-v8a/libmagiskboot.so not found inside $APK" >&2; exit 1
    fi
    if [[ ! -s "module/bin/magiskboot" ]]; then
        echo "ERROR: extracted magiskboot is empty" >&2; exit 1
    fi
    rm "$APK"
fi

# Build kp-safemode helper (queries SUPERCALL_SU_GET_SAFEMODE).
# Cross-compile with Android NDK clang when available; skip on local builds
# where the toolchain isn't installed (the WebUI handles missing-binary
# gracefully).
if [[ ! -f "module/bin/kp-safemode" && -n "$ANDROID_NDK_HOME" ]]; then
    echo "Building kp-safemode with NDK clang..."
    NDK_CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
    if [[ ! -x "$NDK_CLANG" ]]; then
        # Fall back to the generic clang if the API-level-prefixed one is missing.
        NDK_CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
    fi
    if [[ -x "$NDK_CLANG" ]]; then
        "$NDK_CLANG" -static -O2 -Wall -Wextra -o module/bin/kp-safemode module/tools/kp-safemode.c
        chmod +x module/bin/kp-safemode
        echo "✓ kp-safemode built"
    else
        echo "⚠ NDK clang not found at $NDK_CLANG; skipping kp-safemode"
    fi
fi

# Note: the anti-detect KPM suite (module/kpms/*.c) used to be built
# inline here. As of v0.3.0-rc7, KPMs are no longer built into the
# PatchNest module. They are distributed via the standalone
# Kpm-Repo at https://github.com/Zhanfg/Kpm-Repo and consumed by
# the WebUI's KPM Repository page. Users can add custom KPM
# repositories (including their own forks) without rebuilding the
# PatchNest module. See Kpm-Repo/README.md for the forker guide.
#
# The module/kpms/ source files have been moved to
# https://github.com/Zhanfg/Kpm-Repo/tree/main/modules.

# zip module
commit_number=$(git rev-list --count HEAD)
commit_hash=$(git rev-parse --short HEAD)

cd module
zip -r ../out/PatchNest-${commit_number}-${commit_hash}.zip .
cd ..
