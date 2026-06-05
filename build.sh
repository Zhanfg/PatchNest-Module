#!/bin/bash

if [[ $1 == "clean" ]]; then
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

    local release_json=$(curl -s "$url")

    for pattern in "${patterns[@]}"; do
        local regex="${pattern//\*/.*}"
        local asset_data=$(echo "$release_json" | jq -r ".assets[] | select(.name | test(\"$regex\")) | .name + \"\t\" + .browser_download_url" | head -n 1)
        if [[ -z "$asset_data" ]]; then
            echo "Error: Could not find asset matching $pattern in $repo $tag"
            continue
        fi
        local asset_name=$(echo "$asset_data" | cut -f1)
        local download_url=$(echo "$asset_data" | cut -f2)
        echo "Downloading $asset_name from $download_url"
        curl -L "$download_url" -o "$outdir/$asset_name"
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
    unzip -p "$APK" 'lib/arm64-v8a/libmagiskboot.so' > "module/bin/magiskboot"
    rm "$APK"
fi

# zip module
commit_number=$(git rev-list --count HEAD)
commit_hash=$(git rev-parse --short HEAD)

cd module
zip -r ../out/KPatch-Next-${commit_number}-${commit_hash}.zip .
cd ..
