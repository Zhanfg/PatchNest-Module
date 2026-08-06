#!/bin/bash
# PatchNest reproducible local build entry point.
set -euo pipefail

if [[ "${1:-}" == "clean" ]]; then
    rm -rf out module/bin module/webroot
    exit 0
fi

mkdir -p out module/bin module/webroot

# Build WebUI.
cd webui
pnpm build || { pnpm install && pnpm build; }
cd ..

# Read versions and digests from version.properties.
get_ver() {
    [ -f version.properties ] && grep "^$1[[:space:]]*=" version.properties | cut -d'=' -f2 | xargs | sed 's/^"//;s/"$//'
}

asset_digest_key() {
    local asset_name="$1"
    local tag="$2"
    case "$asset_name" in
        Magisk-*.apk) printf 'magisk_apk_%s\n' "$tag" ;;
        *) printf '%s_%s\n' "${asset_name//[-.]/_}" "$tag" ;;
    esac
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

    local release_json
    release_json=$(curl -fsSL "$url")

    for pattern in "${patterns[@]}"; do
        local regex="${pattern//\*/.*}"
        local asset_data
        asset_data=$(printf '%s' "$release_json" | jq -r ".assets[] | select(.name | test(\"$regex\")) | .name + \"\t\" + .browser_download_url" | head -n 1)
        if [[ -z "$asset_data" ]]; then
            echo "ERROR: could not find asset matching '$pattern' in $repo release $tag" >&2
            exit 1
        fi

        local asset_name download_url
        asset_name=$(printf '%s' "$asset_data" | cut -f1)
        download_url=$(printf '%s' "$asset_data" | cut -f2)
        echo "Downloading $asset_name from $download_url"
        curl -fsSL "$download_url" -o "$outdir/$asset_name"
        if [[ ! -s "$outdir/$asset_name" ]]; then
            echo "ERROR: downloaded asset is empty: $asset_name" >&2
            exit 1
        fi

        local key expected
        key=$(asset_digest_key "$asset_name" "$tag")
        expected=$(get_ver "$key" || true)
        if [[ -z "$expected" ]]; then
            echo "ERROR: no trusted SHA256 pinned for $key" >&2
            exit 1
        fi
        echo "$expected  $outdir/$asset_name" | sha256sum -c - \
            || { echo "ERROR: SHA256 mismatch for $asset_name" >&2; exit 1; }
    done
}

VERSION_KERNELPATCH=$(get_ver "kernelpatch")
VERSION_KERNELPATCH="${VERSION_KERNELPATCH:-latest}"
VERSION_PATCHNEST=$(get_ver "patchnest")
VERSION_PATCHNEST="${VERSION_PATCHNEST:-latest}"
VERSION_MAGISKBOOT=$(get_ver "magiskboot")
VERSION_MAGISKBOOT="${VERSION_MAGISKBOOT:-latest}"

# Fetch KernelPatch binaries from the public core repository.
if [[ ! -f "module/bin/kpimg" || ! -f "module/bin/kptools" ]]; then
    download_assets "Zhanfg/KernelPatch-Public" "$VERSION_KERNELPATCH" "module/bin" "kpimg-linux" "kptools-android"
    mv module/bin/kpimg-linux module/bin/kpimg
    mv module/bin/kptools-android module/bin/kptools
fi

# Fetch the PatchNest user-space tool.
if [[ ! -f "module/bin/kpatch" ]]; then
    download_assets "Zhanfg/PatchNest" "$VERSION_PATCHNEST" "module/bin" "kpatch-android"
    mv module/bin/kpatch-android module/bin/kpatch
fi

# Fetch and extract magiskboot from the pinned official Magisk APK.
if [[ ! -f "module/bin/magiskboot" ]]; then
    download_assets "topjohnwu/Magisk" "$VERSION_MAGISKBOOT" "module/bin" "Magisk*.apk"

    APK=$(printf '%s\n' module/bin/Magisk*.apk 2>/dev/null | head -n 1)
    if [[ ! -f "$APK" ]]; then
        echo "ERROR: no Magisk APK downloaded" >&2
        exit 1
    fi
    if ! unzip -p "$APK" 'lib/arm64-v8a/libmagiskboot.so' > "module/bin/magiskboot" 2>/dev/null; then
        echo "ERROR: lib/arm64-v8a/libmagiskboot.so not found inside $APK" >&2
        exit 1
    fi
    if [[ ! -s "module/bin/magiskboot" ]]; then
        echo "ERROR: extracted magiskboot is empty" >&2
        exit 1
    fi
    rm "$APK"
fi

# Build kp-safemode when an Android NDK is available locally.
if [[ ! -f "module/bin/kp-safemode" && -n "${ANDROID_NDK_HOME:-}" ]]; then
    echo "Building kp-safemode with NDK clang..."
    NDK_CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
    if [[ ! -x "$NDK_CLANG" ]]; then
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

# KPM sources and catalog artifacts are maintained independently in:
# https://github.com/Zhanfg/PatchNest-Kpms
# PatchNest-Module consumes the generated catalog at runtime and does not
# bundle catalog KPM binaries into the module archive.

commit_number=$(git rev-list --count HEAD)
commit_hash=$(git rev-parse --short HEAD)

cd module
zip -r "../out/PatchNest-${commit_number}-${commit_hash}.zip" .
cd ..
