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
            echo "Error: Could not find asset matching $pattern in $repo $tag" >&2
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
VERSION_KPATCH_NEXT=$(get_ver "kpatch-next")
VERSION_KPATCH_NEXT="${VERSION_KPATCH_NEXT:-latest}"
VERSION_MAGISKBOOT=$(get_ver "magiskboot")
VERSION_MAGISKBOOT="${VERSION_MAGISKBOOT:-latest}"

# Fetch KernelPatch binaries (kpimg, kptools) from public fork
if [[ ! -f "module/bin/kpimg" || ! -f "module/bin/kptools" ]]; then
    download_assets "Zhanfg/KernelPatch-Public" "$VERSION_KERNELPATCH" "module/bin" "kpimg-linux" "kptools-android"
    mv module/bin/kpimg-linux module/bin/kpimg
    mv module/bin/kptools-android module/bin/kptools
fi

# Fetch kpatch user-space tool from KPatch-Next
# (kpuser binary only available from KPatch-Next, not KernelPatch)
if [[ ! -f "module/bin/kpatch" ]]; then
    download_assets "KernelSU-Next/KPatch-Next" "$VERSION_KPATCH_NEXT" "module/bin" "kpatch-android"
    mv module/bin/kpatch-android module/bin/kpatch
fi

# Fetch magiskboot
if [[ ! -f "module/bin/magiskboot" ]]; then
    download_assets "topjohnwu/Magisk" "$VERSION_MAGISKBOOT" "module/bin" "Magisk*.apk"

    APK=$(ls module/bin/Magisk*.apk | head -n 1)
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

# Build the anti-detect KPM suite (module/kpms/*.c -> module/kpms/*.kpm).
# Each .c file becomes a position-independent shared object loaded by
# the KernelPatch supervisor. -shared -fPIC is required for KP modules.
# We also embed a unique build-id section so the WebUI dashboard can
# detect which .kpm is loaded vs. just on disk.
if [[ -n "$ANDROID_NDK_HOME" && -d "module/kpms" ]]; then
    if [[ ! -x "$NDK_CLANG" ]]; then
        NDK_CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
        if [[ ! -x "$NDK_CLANG" ]]; then
            NDK_CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
        fi
    fi
    if [[ -x "$NDK_CLANG" ]]; then
        echo "Building anti-detect KPM suite with NDK clang..."
        mkdir -p module/kpms/built
        BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
        for src in module/kpms/*.c; do
            [[ -f "$src" ]] || continue
            base="$(basename "$src" .c)"
            out="module/kpms/built/${base}.kpm"
            if [[ -f "$out" && "$out" -nt "$src" ]]; then
                echo "  ✓ ${base}.kpm (cached)"
                continue
            fi
            # -shared -fPIC is required for KP module format
            # -nostdlib -fno-builtin keeps the module lean
            # -Wl,-soname= sets the runtime loadable name
            if "$NDK_CLANG" -static -O2 -Wall -Wextra -fPIC \
                -shared -nostdlib -fno-builtin \
                -Wl,--build-id=sha1 \
                -DKPM_BUILD_ID="\"$BUILD_ID\"" \
                -DKPM_BUILD_TIME="\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
                -o "$out" "$src" 2>&1; then
                # Append a small JSON manifest that the WebUI reads.
                # Format: 8-byte magic "KPMM" + 4-byte version + json blob
                # (kept short so the .kpm stays < 32 KB).
                manifest=$(printf '{"id":"%s","build":"%s","time":"%s","size":%d}' \
                    "$base" "$BUILD_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    "$(stat -c %s "$out" 2>/dev/null || echo 0)")
                printf 'KPMM\x01\x00\x00\x00%-5s' "$base" > /tmp/kpm_manifest_hdr
                printf '%s' "$manifest" >> /tmp/kpm_manifest_hdr
                cat "$out" /tmp/kpm_manifest_hdr > "${out}.tmp"
                mv "${out}.tmp" "$out"
                rm /tmp/kpm_manifest_hdr
                chmod 0644 "$out"
                echo "  ✓ ${base}.kpm ($(stat -c %s "$out") bytes)"
            else
                echo "  ✗ ${base} build FAILED" >&2
            fi
        done
    else
        echo "⚠ NDK clang not found; skipping anti-detect KPM build"
    fi
fi

# zip module
commit_number=$(git rev-list --count HEAD)
commit_hash=$(git rev-parse --short HEAD)

cd module
zip -r ../out/KPatch-Next-${commit_number}-${commit_hash}.zip .
cd ..
