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

for command_name in bash cc curl git jq pnpm python3 readelf sha256sum tar unzip zip find sort touch stat; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    }
done

# Provenance must never identify a commit while silently packaging uncommitted
# source. Generated ignored output is allowed; tracked or untracked source is not.
if ! git diff --quiet || ! git diff --cached --quiet \
   || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "ERROR: release build requires a clean Git working tree" >&2
    exit 1
fi

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
        monocypher-*.tar.gz) printf 'monocypher_tar_%s\n' "$tag" ;;
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
    echo "Downloading $asset_name" >&2
    curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 "$download_url" -o "$destination"
    [[ -s "$destination" ]] || {
        echo "ERROR: downloaded asset is empty: $asset_name" >&2
        exit 1
    }

    digest_key=$(asset_digest_key "$asset_name" "$tag")
    digest=$(expected_digest "$digest_key")
    printf '%s  %s\n' "$digest" "$destination" | sha256sum -c - >&2
    printf '%s\n' "$destination"
}

resolve_ndk_clang() {
    [[ -n "${ANDROID_NDK_HOME:-}" ]] || {
        echo "ERROR: ANDROID_NDK_HOME is required" >&2
        return 1
    }
    [[ -f "$ANDROID_NDK_HOME/source.properties" ]] || {
        echo "ERROR: Android NDK source.properties not found" >&2
        return 1
    }

    local actual_revision
    actual_revision=$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' \
        "$ANDROID_NDK_HOME/source.properties" | head -n 1 | tr -d '\r')
    [[ "$actual_revision" == "$VERSION_ANDROID_NDK" ]] || {
        echo "ERROR: Android NDK revision $actual_revision does not match pinned $VERSION_ANDROID_NDK" >&2
        return 1
    }

    local host_tag candidate
    for host_tag in linux-x86_64 darwin-x86_64 darwin-arm64 windows-x86_64; do
        candidate="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host_tag/bin/aarch64-linux-android24-clang"
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if [[ -x "${candidate}.cmd" ]]; then
            printf '%s\n' "${candidate}.cmd"
            return 0
        fi
    done
    echo "ERROR: pinned NDK AArch64 clang was not found" >&2
    return 1
}

MODULE_VERSION=$(get_value module/module.prop version)
MODULE_VERSION_CODE=$(get_value module/module.prop versionCode)
VERSION_KERNELPATCH=$(get_value version.properties kernelpatch)
VERSION_PATCHNEST=$(get_value version.properties patchnest)
VERSION_MAGISKBOOT=$(get_value version.properties magiskboot)
VERSION_MONOCYPHER=$(get_value version.properties monocypher)
VERSION_MONOCYPHER_COMMIT=$(get_value version.properties monocypher_commit)
VERSION_ANDROID_NDK=$(get_value version.properties android_ndk)
KPM_SIGNING_PUBLIC_KEY=$(get_value version.properties kpm_signing_public_key)
KPM_SIGNING_KEY_FINGERPRINT=$(get_value version.properties kpm_signing_key_fingerprint_sha256)
KPM_SIGNING_KEY_STATUS=$(get_value version.properties kpm_signing_key_status)

[[ "$MODULE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || {
    echo "ERROR: invalid module version: $MODULE_VERSION" >&2
    exit 1
}
[[ "$MODULE_VERSION_CODE" =~ ^[0-9]+$ ]] || {
    echo "ERROR: invalid module versionCode: $MODULE_VERSION_CODE" >&2
    exit 1
}
[[ "$VERSION_MONOCYPHER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: invalid pinned Monocypher commit" >&2
    exit 1
}
[[ "$KPM_SIGNING_PUBLIC_KEY" =~ ^[0-9a-f]{64}$ ]] || {
    echo "ERROR: invalid KPM signing public key" >&2
    exit 1
}
[[ "$KPM_SIGNING_KEY_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || {
    echo "ERROR: invalid KPM signing-key fingerprint" >&2
    exit 1
}
case "$KPM_SIGNING_KEY_STATUS" in
    development|production) ;;
    *) echo "ERROR: invalid KPM signing-key status" >&2; exit 1 ;;
esac

NDK_CLANG=$(resolve_ndk_clang)
python3 scripts/verify_signing_key_policy.py --root "$ROOT"
python3 scripts/verify_release_metadata.py --root "$ROOT"

rm -rf "$OUT_DIR" "$BIN_DIR" "$WEBROOT_DIR"
mkdir -p "$OUT_DIR" "$BIN_DIR" "$WEBROOT_DIR" "$OUT_DIR/deps"

(
    cd webui
    pnpm install --frozen-lockfile
    pnpm build --emptyOutDir
)

KPIMG_ASSET=$(download_release_asset \
    Zhanfg/KernelPatch-Public "$VERSION_KERNELPATCH" "$BIN_DIR" 'kpimg-linux')
KPTOOLS_ASSET=$(download_release_asset \
    Zhanfg/KernelPatch-Public "$VERSION_KERNELPATCH" "$BIN_DIR" 'kptools-android')
KPATCH_ASSET=$(download_release_asset \
    Zhanfg/PatchNest "$VERSION_PATCHNEST" "$BIN_DIR" 'kpatch-android')
MAGISK_APK=$(download_release_asset \
    topjohnwu/Magisk "$VERSION_MAGISKBOOT" "$BIN_DIR" 'Magisk-*.apk')
MONOCYPHER_ASSET=$(download_release_asset \
    LoupVaillant/Monocypher "$VERSION_MONOCYPHER" "$OUT_DIR/deps" \
    "monocypher-${VERSION_MONOCYPHER}.tar.gz")

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

MONOCYPHER_DIR="$OUT_DIR/monocypher-$VERSION_MONOCYPHER"
mkdir -p "$MONOCYPHER_DIR"
tar -xzf "$MONOCYPHER_ASSET" -C "$MONOCYPHER_DIR" --strip-components=1
for required in \
    LICENCE.md \
    src/monocypher.c \
    src/monocypher.h \
    src/optional/monocypher-ed25519.c \
    src/optional/monocypher-ed25519.h; do
    [[ -s "$MONOCYPHER_DIR/$required" ]] || {
        echo "ERROR: Monocypher archive missing $required" >&2
        exit 1
    }
done

VERIFY_SOURCE="$ROOT/module/tools/kpm-verify.c"
HOST_VERIFY="$OUT_DIR/kpm-verify-host"
COMMON_VERIFY_SOURCES=(
    "$VERIFY_SOURCE"
    "$MONOCYPHER_DIR/src/monocypher.c"
    "$MONOCYPHER_DIR/src/optional/monocypher-ed25519.c"
)
COMMON_VERIFY_FLAGS=(
    -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror
    -I"$MONOCYPHER_DIR/src"
    -I"$MONOCYPHER_DIR/src/optional"
)

cc "${COMMON_VERIFY_FLAGS[@]}" "${COMMON_VERIFY_SOURCES[@]}" -o "$HOST_VERIFY"
PROBE_PUBLIC_KEY=a6cee3371d164daf9ad2ed38ecaf1d492e7867fc6df31f810e69eaa0dd45259b
PROBE_SIGNATURE=886199b494a8dcb9ddec3a48385f4ea7e3cbefcc90198c6c807fd2434125b20e32f1b8cdd817e782f7fcf80860c4a32f7c49006089a4efefb4b734bbcb30f703
printf '%s' probe >"$OUT_DIR/kpm-verify-message.bin"
"$HOST_VERIFY" "$PROBE_PUBLIC_KEY" "$PROBE_SIGNATURE" "$OUT_DIR/kpm-verify-message.bin"
printf '%s' tampered >"$OUT_DIR/kpm-verify-message.bin"
if "$HOST_VERIFY" "$PROBE_PUBLIC_KEY" "$PROBE_SIGNATURE" "$OUT_DIR/kpm-verify-message.bin"; then
    echo "ERROR: native verifier accepted a tampered message" >&2
    exit 1
fi
rm -f "$HOST_VERIFY" "$OUT_DIR/kpm-verify-message.bin"

"$NDK_CLANG" \
    -std=c11 -D_GNU_SOURCE -static -fPIE -pie -Os \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -Wall -Wextra -Werror \
    -I"$MONOCYPHER_DIR/src" \
    -I"$MONOCYPHER_DIR/src/optional" \
    "${COMMON_VERIFY_SOURCES[@]}" \
    -o "$BIN_DIR/kpm-verify"
[[ -s "$BIN_DIR/kpm-verify" ]] || {
    echo "ERROR: Android KPM verifier build produced no output" >&2
    exit 1
}
readelf -h "$BIN_DIR/kpm-verify" | grep -Eq 'Machine:[[:space:]]+AArch64' || {
    echo "ERROR: KPM verifier is not AArch64" >&2
    exit 1
}
if readelf -l "$BIN_DIR/kpm-verify" | grep -q 'INTERP'; then
    echo "ERROR: KPM verifier unexpectedly has a dynamic interpreter" >&2
    exit 1
fi

"$NDK_CLANG" -static -O2 -Wall -Wextra -Werror \
    -o "$BIN_DIR/kp-safemode" module/tools/kp-safemode.c
[[ -s "$BIN_DIR/kp-safemode" ]] || {
    echo "ERROR: kp-safemode build produced no output" >&2
    exit 1
}

chmod 0755 \
    "$BIN_DIR/kpimg" "$BIN_DIR/kptools" "$BIN_DIR/kpatch" \
    "$BIN_DIR/magiskboot" "$BIN_DIR/kpm-verify" "$BIN_DIR/kp-safemode"

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git show -s --format=%ct HEAD)}
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
    echo "ERROR: SOURCE_DATE_EPOCH must be an integer" >&2
    exit 1
}
mkdir -p "$STAGE_DIR"
cp -a module/. "$STAGE_DIR/"
mkdir -p "$STAGE_DIR/licenses"
cp "$MONOCYPHER_DIR/LICENCE.md" "$STAGE_DIR/licenses/Monocypher-LICENCE.md"
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
  "schemaVersion": 2,
  "sourceCommit": "$COMMIT_SHA",
  "sourceTreeStatus": "clean",
  "sourceDateEpoch": $SOURCE_DATE_EPOCH,
  "moduleVersion": "$MODULE_VERSION",
  "moduleVersionCode": $MODULE_VERSION_CODE,
  "archive": "$(basename "$ARCHIVE")",
  "archiveSha256": "$ARCHIVE_SHA",
  "archiveSize": $ARCHIVE_SIZE,
  "kernelPatchVersion": "$VERSION_KERNELPATCH",
  "patchNestCliVersion": "$VERSION_PATCHNEST",
  "magiskVersion": "$VERSION_MAGISKBOOT",
  "monocypherVersion": "$VERSION_MONOCYPHER",
  "monocypherCommit": "$VERSION_MONOCYPHER_COMMIT",
  "androidNdkRevision": "$VERSION_ANDROID_NDK",
  "kpmVerifier": "static-monocypher-ed25519",
  "kpmSigningPublicKey": "$KPM_SIGNING_PUBLIC_KEY",
  "kpmSigningKeyFingerprintSha256": "$KPM_SIGNING_KEY_FINGERPRINT",
  "kpmSigningKeyStatus": "$KPM_SIGNING_KEY_STATUS",
  "kpSafemode": "built"
}
EOF

if unzip -Z1 "$ARCHIVE" | grep -Eq '(^|/)(\.git|node_modules|audit-output|out)(/|$)'; then
    echo "ERROR: package contains build-only files" >&2
    exit 1
fi
for required in \
    bin/kpm-verify \
    licenses/Monocypher-LICENCE.md \
    runtime_compat_check.sh; do
    unzip -Z1 "$ARCHIVE" | grep -Fxq "$required" || {
        echo "ERROR: package missing $required" >&2
        exit 1
    }
done

printf 'Built %s\nSHA256 %s\n' "$ARCHIVE" "$ARCHIVE_SHA"
