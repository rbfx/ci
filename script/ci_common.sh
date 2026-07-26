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

    local parsed_platform=''
    if ! parsed_platform=$(
        python3 "$ci_common_script_dir/ci_data.py" \
            platform-tsv "$ci_platform_tag"
    ); then
        return 1
    fi
    IFS=$'\t' read -r \
        ci_platform \
        ci_compiler \
        ci_arch \
        ci_lib_type \
        ci_platform_group \
        <<< "$parsed_platform"
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
