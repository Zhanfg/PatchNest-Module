#!/usr/bin/env bash
# PatchNest reproducible local build entry point.
set -euo pipefail
IFS=$'\n\t'
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

OUT_DIR="$ROOT/out"
BIN_DIR="$ROOT/module/bin"
WEBROOT_DIR="$ROOT/module/webroot"
STAGE_DIR="$OUT_DIR/stage"
ARCHIVE="$OUT_DIR/PatchNest-Module.zip"

if [[ "${1:-}" == "clean" ]]; then
    rm -rf "$OUT_DIR" "$BIN_DIR" "$WEBROOT_DIR"
    exit 0
fi
if [[ $# -gt 0 ]]; then
    echo "ERROR: unsupported argument: $1" >&2
    exit 2
fi

for command_name in bash curl git jq pnpm sha256sum unzip zip find sort touch stat; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    }
done

get_value() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || {
        echo "ERROR: missing metadata file: $file" >&2
        return 1
    }
    local value
    value=$(grep -F "${key}=" "$file" | head -n 1 | cut -d= -f2- | xargs | sed 's/^"//;s/"$//')
    [[ -n "$value" ]] || {
        echo "ERROR: missing required key '$key' in $file" >&2
        return 1
    }
    printf '%s\n' "$value"
}

asset_digest_key() {
    local asset_name="$1"
    local tag="$2"
    case "$asset_name" in
        Magisk-*.apk) printf 'magisk_apk_%s\n' "$tag" ;;
        *) printf '%s_%s\n' "${asset_name//[-.]/_}" "$tag" ;;
    esac
}

expected_digest() {
    local key="$1"
    local digest
    digest=$(get_value version.properties "$key")
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "ERROR: invalid trusted SHA256 for $key" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

download_release_asset() {
    local repository="$1"
    local tag="$2"
    local output_directory="$3"
    local pattern="$4"

    [[ "$tag" != "latest" ]] || {
        echo "ERROR: mutable latest release is forbidden for $repository" >&2
        exit 1
    }

    local release_url="https://api.github.com/repos/$repository/releases/tags/$tag"
    local release_json asset_data asset_name download_url digest_key digest
    release_json=$(curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 "$release_url")

    local regex="${pattern//\*/.*}"
    asset_data=$(printf '%s' "$release_json" \
        | jq -r ".assets[] | select(.name | test(\"^${regex}$\")) | .name + \"\\t\" + .browser_download_url" \
        | head -n 1)
    [[ -n "$asset_data" ]] || {
        echo "ERROR: asset '$pattern' not found in $repository release $tag" >&2
        exit 1
    }

    asset_name=${asset_data%%$'\t'*}
    download_url=${asset_data#*$'\t'}
    [[ "$download_url" == https://github.com/*/releases/download/* ]] || {
        echo "ERROR: unexpected asset URL: $download_url" >&2
        exit 1
    }

    mkdir -p "$output_directory"
    local destination="$output_directory/$asset_name"
    echo "Downloading $asset_name"
    curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 "$download_url" -o "$destination"
    [[ -s "$destination" ]] || {
        echo "ERROR: downloaded asset is empty: $asset_name" >&2
        exit 1
    }

    digest_key=$(asset_digest_key "$asset_name" "$tag")
    digest=$(expected_digest "$digest_key")
    printf '%s  %s\n' "$digest" "$destination" | sha256sum -c -
    printf '%s\n' "$destination"
}

MODULE_VERSION=$(get_value module/module.prop version)
MODULE_VERSION_CODE=$(get_value module/module.prop versionCode)
VERSION_KERNELPATCH=$(get_value version.properties kernelpatch)
VERSION_PATCHNEST=$(get_value version.properties patchnest)
VERSION_MAGISKBOOT=$(get_value version.properties magiskboot)

[[ "$MODULE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || {
    echo "ERROR: invalid module version: $MODULE_VERSION" >&2
    exit 1
}
[[ "$MODULE_VERSION_CODE" =~ ^[0-9]+$ ]] || {
    echo "ERROR: invalid module versionCode: $MODULE_VERSION_CODE" >&2
    exit 1
}

# Validate metadata before spending time on dependency downloads.
python3 scripts/verify_release_metadata.py --root "$ROOT"

rm -rf "$OUT_DIR" "$BIN_DIR" "$WEBROOT_DIR"
mkdir -p "$OUT_DIR" "$BIN_DIR" "$WEBROOT_DIR"

# Build the WebUI strictly from the committed lockfile.
(
    cd webui
    pnpm install --frozen-lockfile
    pnpm build --emptyOutDir
)

# Download every executable from its immutable release on every build. This
# avoids silently trusting stale or locally replaced module/bin files.
KPIMG_ASSET=$(download_release_asset \
    Zhanfg/KernelPatch-Public "$VERSION_KERNELPATCH" "$BIN_DIR" 'kpimg-linux')
KPTOOLS_ASSET=$(download_release_asset \
    Zhanfg/KernelPatch-Public "$VERSION_KERNELPATCH" "$BIN_DIR" 'kptools-android')
KPATCH_ASSET=$(download_release_asset \
    Zhanfg/PatchNest "$VERSION_PATCHNEST" "$BIN_DIR" 'kpatch-android')
MAGISK_APK=$(download_release_asset \
    topjohnwu/Magisk "$VERSION_MAGISKBOOT" "$BIN_DIR" 'Magisk-*.apk')

mv "$KPIMG_ASSET" "$BIN_DIR/kpimg"
mv "$KPTOOLS_ASSET" "$BIN_DIR/kptools"
mv "$KPATCH_ASSET" "$BIN_DIR/kpatch"

if ! unzip -p "$MAGISK_APK" 'lib/arm64-v8a/libmagiskboot.so' >"$BIN_DIR/magiskboot"; then
    echo "ERROR: lib/arm64-v8a/libmagiskboot.so not found in verified Magisk APK" >&2
    exit 1
fi
[[ -s "$BIN_DIR/magiskboot" ]] || {
    echo "ERROR: extracted magiskboot is empty" >&2
    exit 1
}
rm -f "$MAGISK_APK"
chmod 0755 "$BIN_DIR/kpimg" "$BIN_DIR/kptools" "$BIN_DIR/kpatch" "$BIN_DIR/magiskboot"

# Build kp-safemode only from a specifically provided NDK. Its absence is
# explicit in the provenance manifest rather than silently changing the ZIP.
KPSAFEMODE_STATUS=absent
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    NDK_CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
    [[ -x "$NDK_CLANG" ]] || {
        echo "ERROR: Android NDK clang not found: $NDK_CLANG" >&2
        exit 1
    }
    "$NDK_CLANG" -static -O2 -Wall -Wextra -Werror \
        -o "$BIN_DIR/kp-safemode" module/tools/kp-safemode.c
    [[ -s "$BIN_DIR/kp-safemode" ]] || {
        echo "ERROR: kp-safemode build produced no output" >&2
        exit 1
    }
    chmod 0755 "$BIN_DIR/kp-safemode"
    KPSAFEMODE_STATUS=built
fi

# Build in a staging directory so source mtimes and local filesystem ordering
# cannot change the archive. SOURCE_DATE_EPOCH defaults to the source commit.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git show -s --format=%ct HEAD)}
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
    echo "ERROR: SOURCE_DATE_EPOCH must be an integer" >&2
    exit 1
}
mkdir -p "$STAGE_DIR"
cp -a module/. "$STAGE_DIR/"
find "$STAGE_DIR" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

(
    cd "$STAGE_DIR"
    LC_ALL=C find . -type f -print | LC_ALL=C sort | zip -X -q "$ARCHIVE" -@
)
[[ -s "$ARCHIVE" ]] || {
    echo "ERROR: package archive is empty" >&2
    exit 1
}

ARCHIVE_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
ARCHIVE_SIZE=$(stat -c '%s' "$ARCHIVE")
COMMIT_SHA=$(git rev-parse HEAD)

printf '%s  %s\n' "$ARCHIVE_SHA" "$(basename "$ARCHIVE")" \
    >"$OUT_DIR/PatchNest-Module.zip.sha256"
cat >"$OUT_DIR/build-provenance.json" <<EOF
{
  "schemaVersion": 1,
  "sourceCommit": "$COMMIT_SHA",
  "sourceDateEpoch": $SOURCE_DATE_EPOCH,
  "moduleVersion": "$MODULE_VERSION",
  "moduleVersionCode": $MODULE_VERSION_CODE,
  "archive": "$(basename "$ARCHIVE")",
  "archiveSha256": "$ARCHIVE_SHA",
  "archiveSize": $ARCHIVE_SIZE,
  "kernelPatchVersion": "$VERSION_KERNELPATCH",
  "patchNestCliVersion": "$VERSION_PATCHNEST",
  "magiskVersion": "$VERSION_MAGISKBOOT",
  "kpSafemode": "$KPSAFEMODE_STATUS"
}
EOF

# Confirm the archive contains only the staged module and no build workspace.
if unzip -Z1 "$ARCHIVE" | grep -Eq '(^|/)(\.git|node_modules|audit-output|out)(/|$)'; then
    echo "ERROR: package contains build-only files" >&2
    exit 1
fi

printf 'Built %s\nSHA256 %s\n' "$ARCHIVE" "$ARCHIVE_SHA"
