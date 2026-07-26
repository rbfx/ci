#!/usr/bin/env bash

# Shared primitives for rbfx CI scripts. This file is sourced, not executed.

ci_common_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

normalize-path() {
    printf '%s\n' "$1" | tr "\\" "/" 2>/dev/null
}

write-github-output() {
    local key=$1
    local value=$2
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

write-github-env() {
    local key=$1
    local value=$2
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
    fi
}

parse-platform-tag() {
    if [[ -z "${ci_platform_tag:-}" ]]; then
        echo "Error: ci_platform_tag is required"
        return 1
    fi

    local extra=''
    IFS='-' read -r ci_platform ci_compiler ci_arch ci_lib_type extra <<< "$ci_platform_tag"
    if [[ -n "$extra" || -z "$ci_lib_type" ]]; then
        echo "Error: invalid CI platform tag: $ci_platform_tag"
        return 1
    fi

    case "$ci_platform_tag" in
        windows-msvc-x64-dll|windows-msvc-x64-lib|\
        windows-msvc-x86-dll|windows-msvc-x86-lib|\
        linux-gcc-x64-dll|linux-gcc-x64-lib|\
        linux-clang-x64-dll|linux-clang-x64-lib|\
        macos-clang-arm64-dll|macos-clang-arm64-lib|\
        macos-clang-x64-dll|macos-clang-x64-lib|\
        uwp-msvc-x64-dll|uwp-msvc-x64-lib|\
        android-clang-arm64-dll|android-clang-arm-dll|\
        android-clang-x64-dll|\
        ios-clang-arm-lib|ios-clang-arm64-lib|\
        web-emscripten-wasm-lib)
            ;;
        *)
            echo "Error: unsupported CI platform tag: $ci_platform_tag"
            return 1
            ;;
    esac
}

detect-processor-count() {
    case "$ci_platform" in
        linux|android|web)
            ci_number_of_processors=$(nproc)
            ;;
        macos|ios)
            ci_number_of_processors=$(sysctl -n hw.ncpu)
            ;;
        windows|uwp)
            ci_number_of_processors=${NUMBER_OF_PROCESSORS:-1}
            ;;
        *)
            echo "Error: unsupported CI platform: $ci_platform"
            return 1
            ;;
    esac
}

platform-group() {
    case "$ci_platform" in
        windows|linux|macos) printf 'desktop\n' ;;
        android|ios) printf 'mobile\n' ;;
        uwp) printf 'uwp\n' ;;
        web) printf 'web\n' ;;
        *)
            echo "Error: unsupported CI platform: $ci_platform"
            return 1
            ;;
    esac
}

parse-path-list() {
    python3 "$ci_common_script_dir/ci_data.py" parse-list paths "$1"
}

parse-string-list() {
    python3 "$ci_common_script_dir/ci_data.py" parse-list strings "$1"
}

copy-runtime-libraries-for-file() {
    local file=$1
    local dir
    dir=$(dirname "$file")
    local -a dependencies=()
    mapfile -t dependencies < <(ldd "$file" | awk '{print $3}' | grep -E '^/' || true)
    shopt -s nocasematch
    local dep=''
    for dep in "${dependencies[@]}"; do
        if [[ "$dep" =~ (vcruntime.+dll)|(msvcp.+dll)|(D3DCOMPILER.*dll) ]]; then
            local dep_name
            dep_name=$(basename "$dep")
            if [[ "$dep" != "$dir/$dep_name" && ! -f "$dir/$dep_name" ]]; then
                echo "Depends on $dep, making a copy to $dir"
                cp "$dep" "$dir"
            fi
        fi
    done
    shopt -u nocasematch
}

copy-runtime-libraries-for-executables() {
    local dir=$1
    local -a executable_files=()
    mapfile -t executable_files < <(find "$dir" -type f -executable)
    local file=''
    for file in "${executable_files[@]}"; do
        echo "Copying dependencies for $file"
        copy-runtime-libraries-for-file "$file"
    done
}
