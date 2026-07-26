#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci_common.sh
source "$script_dir/ci_common.sh"

usage() {
    echo "Usage: $0 <download-cached-sdk|sanitize-cached-sdk|copy-cached-sdk|download-nuget-sdks|release-mobile-artifacts|publish-to-itch> [arguments]"
}

download-cached-sdk-archive() {
    local repository=$1
    local extract_dir=$2
    local expected_id=$3
    local asset_name="rebelfork-sdk-${ci_platform_tag}-latest.7z"
    local url="https://github.com/${repository}/releases/download/latest/${asset_name}"
    local temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
    local temp_dir
    temp_dir=$(mktemp -d "${temp_root%/}/rbfx-sdk-cache.XXXXXX")
    local archive="$temp_dir/$asset_name"
    local unpack_dir="$temp_dir/unpacked"
    local id_dir="$temp_dir/id"

    echo "Attempting to download: $url"
    if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
        if ! gh release download latest \
            --repo "$repository" \
            --pattern "$asset_name" \
            --dir "$temp_dir"; then
            echo "Failed to download cached SDK with gh"
            rm -rf "$temp_dir"
            return 1
        fi
    elif ! curl -fsSL "$url" -o "$archive"; then
        echo "Failed to download cached SDK"
        rm -rf "$temp_dir"
        return 1
    fi

    mkdir -p "$id_dir"
    if ! 7z e -y "$archive" "${asset_name%.7z}/thirdparty-id.txt" -o"$id_dir" >/dev/null 2>&1; then
        echo "Could not extract cached SDK ThirdParty ID"
        rm -rf "$temp_dir"
        return 1
    fi

    local cached_id
    cached_id=$(<"$id_dir/thirdparty-id.txt")
    echo "Cached ID: $cached_id"
    echo "Expected ID: $expected_id"
    if [[ "$cached_id" != "$expected_id" ]]; then
        echo "ID mismatch! Download is outdated."
        rm -rf "$temp_dir"
        return 1
    fi

    mkdir -p "$unpack_dir"
    if ! 7z x -y "$archive" -o"$unpack_dir" >/dev/null; then
        echo "Failed to extract cached SDK"
        rm -rf "$temp_dir"
        return 1
    fi

    local extracted_dir="$unpack_dir/${asset_name%.7z}"
    if [[ ! -d "$extracted_dir" ]]; then
        echo "Cached SDK archive has an unexpected layout"
        rm -rf "$temp_dir"
        return 1
    fi
    if [[ -z "$extract_dir" || "$extract_dir" == '/' ]]; then
        echo "Error: invalid cached SDK extraction directory"
        rm -rf "$temp_dir"
        return 1
    fi
    mkdir -p "$(dirname "$extract_dir")"
    rm -rf "$extract_dir"
    mv "$extracted_dir" "$extract_dir"
    rm -rf "$temp_dir"
    echo "Extracted cached SDK into $extract_dir"
}

download-cached-sdk() {
    local repository="${DOWNLOAD_SDK_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
    local extract_dir="${ci_workspace_dir}/cached-sdk"
    if [[ -z "$repository" ]]; then
        echo "Error: DOWNLOAD_SDK_REPOSITORY or GITHUB_REPOSITORY is required"
        return 1
    fi

    if download-cached-sdk-archive "$repository" "$extract_dir" "$ci_hash_thirdparty"; then
        write-github-output sdk_cached true
    else
        write-github-output sdk_cached false
        return 1
    fi
}

sanitize-cached-sdk() {
    if [[ $# -ne 1 ]]; then
        echo "Error: sanitize-cached-sdk requires <sdk_dir>"
        return 1
    fi
    local sdk_dir=$1
    if [[ "$ci_platform" == 'windows' || "$ci_platform" == 'uwp' ]]; then
        sdk_dir=$(cygpath "$sdk_dir")
    fi
    rm -rf "$sdk_dir/share/Urho3D" "$sdk_dir/share/Urho3DTools"
}

copy-cached-sdk() {
    if [[ $# -ne 2 ]]; then
        echo "Error: copy-cached-sdk requires <src_dir> <dst_dir>"
        return 1
    fi
    local src=$1
    local dst=$2
    if [[ "$ci_platform" == 'windows' || "$ci_platform" == 'uwp' ]]; then
        src=$(cygpath "$src")
        dst=$(cygpath "$dst")
    fi
    mkdir -p "$dst"
    echo "Copying files from cached SDK..."
    local file=''
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            mkdir -p "$dst/$(dirname "$file")"
            cp -p "$src/$file" "$dst/$file"
        fi
    done < "$src/thirdparty-files.txt"
    echo "Cached SDK files copied successfully"
}

download-nuget-sdks() {
    if [[ $# -ne 2 ]]; then
        echo "Error: download-nuget-sdks requires <github_repository> <output_dir>"
        return 1
    fi
    local github_repository=$1
    local output_dir=$2
    local -a platforms=(
        windows-msvc-x64-dll
        linux-gcc-x64-dll
        macos-clang-x64-dll
        macos-clang-arm64-dll
        uwp-msvc-x64-dll
    )
    local platform=''
    for platform in "${platforms[@]}"; do
        local sdk_name="rebelfork-sdk-${platform}-latest.7z"
        echo "Downloading $sdk_name..."
        gh release download latest --repo "$github_repository" --pattern "$sdk_name" --dir .
        7z x -y "$sdk_name" "${sdk_name%.7z}/bin/*" -o"$output_dir"
        rm "$sdk_name"
    done
}

release-mobile-artifacts() {
    if [[ -z "${GH_TOKEN:-}" ]]; then
        echo "No GH_TOKEN detected. Can't release artifacts."
        return 1
    fi

    local artifact=''
    local release_configuration='RelWithDebInfo'
    if [[ -n "${ci_build_types:-}" ]]; then
        release_configuration=$(
            python3 "$script_dir/ci_data.py" \
                get-build-type "$ci_build_types" rel RelWithDebInfo
        )
    fi
    case "$ci_platform" in
        android)
            artifact=$(find . -iname '*release*.apk' -type f | head -n 1)
            ;;
        ios)
            artifact=$(find . -path "*/${release_configuration}/*.app" -type d | head -n 1)
            ;;
        *)
            echo "Error: release-mobile-artifacts requires Android or iOS"
            return 1
            ;;
    esac
    if [[ -z "$artifact" ]]; then
        echo "Warning: no mobile artifact found"
        return 1
    fi

    local archive_name="rebelfork-bin-${ci_platform_tag}-latest.7z"
    7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on "$archive_name" "$artifact"
    gh release upload latest "$archive_name" --repo "$GITHUB_REPOSITORY" --clobber
    echo "Released $archive_name"
}

publish-to-itch() {
    if [[ -z "${BUTLER_API_KEY:-}" ]]; then
        echo "No BUTLER_API_KEY detected. Can't publish to itch.io."
        return 0
    fi

    local build_type="${1:-rel}"
    if [[ "$ci_platform" == 'windows' ]]; then
        copy-runtime-libraries-for-executables "$ci_build_dir/bin"
    fi
    butler push "$ci_build_dir/bin" \
        "rebelfork/rebelfork:${ci_platform}-${ci_arch}-${ci_lib_type}-${ci_compiler}-${build_type}"
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi
command=$1
shift
case "$command" in
    download-cached-sdk) download-cached-sdk "$@" ;;
    sanitize-cached-sdk) sanitize-cached-sdk "$@" ;;
    copy-cached-sdk) copy-cached-sdk "$@" ;;
    download-nuget-sdks) download-nuget-sdks "$@" ;;
    release-mobile-artifacts) release-mobile-artifacts "$@" ;;
    publish-to-itch) publish-to-itch "$@" ;;
    *)
        echo "Error: unknown artifact command: $command"
        usage
        exit 1
        ;;
esac
