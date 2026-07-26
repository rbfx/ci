#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci_common.sh
source "$script_dir/ci_common.sh"

usage() {
    echo "Usage: $0 <setup-environment|dependencies|setup-emsdk|build-swig|setup-package-tool|resolve-cmake-prefix-path>"
}

setup-environment() {
    parse-platform-tag
    detect-processor-count

    case "${ci_profile:-engine}" in
        engine|downstream) ;;
        *)
            echo "Error: unsupported CI profile: ${ci_profile}"
            return 1
            ;;
    esac

    local ci_short_sha="${GITHUB_SHA:-}"
    ci_short_sha=${ci_short_sha:0:8}
    local ci_hash_thirdparty=''
    if [[ "${ci_profile:-engine}" == 'engine' ]]; then
        local hash_script="${ci_source_dir}/CMake/Modules/GetThirdPartyHash.cmake"
        if ! ci_hash_thirdparty=$(cmake \
            -DDIRECTORY_PATH="${ci_source_dir}/Source/ThirdParty" \
            -DHASH_FORMAT=short \
            -P "$hash_script" 2>&1); then
            echo "$ci_hash_thirdparty"
            return 1
        fi
    fi

    local ci_cache_id="${ccache_prefix:-}-${ci_platform_tag}"

    write-github-env ci_number_of_processors "$ci_number_of_processors"
    write-github-env ci_short_sha "$ci_short_sha"
    write-github-env ci_cache_id "$ci_cache_id"
    write-github-env ci_hash_thirdparty "$ci_hash_thirdparty"
    write-github-env ci_platform_group "$ci_platform_group"
    write-github-env ci_platform "$ci_platform"
    write-github-env ci_compiler "$ci_compiler"
    write-github-env ci_arch "$ci_arch"
    write-github-env ci_lib_type "$ci_lib_type"
}

install-dependencies() {
    case "$ci_platform" in
        linux)
            sudo apt-get update
            sudo apt-get install -y \
                ninja-build ccache xvfb p7zip-full \
                libgl1-mesa-dev libxcursor-dev libxi-dev libxinerama-dev \
                libxrandr-dev libxrender-dev libxss-dev libasound2-dev \
                libpulse-dev libibus-1.0-dev libdbus-1-dev libreadline6-dev \
                libudev-dev uuid-dev libtbb-dev
            ;;
        web)
            sudo apt-get update
            sudo apt-get install -y --no-install-recommends \
                uuid-dev ninja-build ccache p7zip-full libopengl0
            ;;
        android)
            sudo apt-get update
            sudo apt-get install -y --no-install-recommends \
                uuid-dev ninja-build ccache p7zip-full
            ;;
        macos|ios)
            brew install ccache bash
            ;;
        windows)
            choco install -y ccache 7zip
            ;;
        uwp)
            choco install -y ccache 7zip
            choco install -y windows-sdk-10-version-2104-all
            ;;
        *)
            echo "Error: unsupported CI platform: $ci_platform"
            return 1
            ;;
    esac
}

setup-emsdk() {
    local emsdk_dir="${1:-${ci_workspace_dir}/emsdk}"
    emsdk_dir=$(normalize-path "$emsdk_dir")

    cd "$emsdk_dir"
    ./emsdk install latest
    ./emsdk activate latest

    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf 'PATH=%s:%s:%s\n' "$PATH" "$emsdk_dir" "$emsdk_dir/upstream/emscripten" >> "$GITHUB_ENV"
        printf 'EMSDK=%s\n' "$emsdk_dir" >> "$GITHUB_ENV"
    else
        export PATH="$PATH:$emsdk_dir:$emsdk_dir/upstream/emscripten"
        export EMSDK="$emsdk_dir"
    fi
}

build-swig() {
    local processors="${ci_number_of_processors:-}"
    if [[ -z "$processors" ]]; then
        detect-processor-count
        processors=$ci_number_of_processors
    fi

    local binary_dir="${ci_workspace_dir}/swig-build"
    local exe=''
    local swig_exe=''
    cmake -S "${ci_source_dir}/Source/ThirdParty/swig" -B "$binary_dir" \
        -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$binary_dir" \
        -DCMAKE_BUILD_TYPE=Release -DDESKTOP=ON -DURHO3D_CSHARP=ON
    cmake --build "$binary_dir" --config Release --parallel "$processors"

    if [[ "$ci_platform" == 'uwp' ]]; then
        exe='.exe'
    fi
    if [[ -f "$binary_dir/swig$exe" ]]; then
        swig_exe="$binary_dir/swig$exe"
    else
        swig_exe="$binary_dir/Release/swig$exe"
    fi
    write-github-env SWIG_EXECUTABLE "$swig_exe"
    if [[ -z "${GITHUB_ENV:-}" ]]; then
        printf 'SWIG_EXECUTABLE=%s\n' "$swig_exe"
    fi
}

setup-package-tool() {
    local venv="${ci_workspace_dir}/venv-PackageTool"
    python3 -m venv "$venv"

    local python_exe="$venv/Scripts/python.exe"
    if [[ -f "$venv/bin/python" ]]; then
        python_exe="$venv/bin/python"
    fi
    "$python_exe" -m pip install lz4

    local package_tool_executable="$python_exe;${ci_source_dir}/Source/Tools/PackageTool/PackageTool.py"
    echo "Using Python PackageTool fallback: $package_tool_executable"
    write-github-env PACKAGE_TOOL_EXECUTABLE "$package_tool_executable"
    if [[ -z "${GITHUB_ENV:-}" ]]; then
        printf 'PACKAGE_TOOL_EXECUTABLE=%s\n' "$package_tool_executable"
    fi
}

resolve-cmake-prefix-path() {
    local prefix_paths_value="${INPUT_CMAKE_PREFIX_PATH:-[]}"
    local workspace_dir="${INPUT_WORKSPACE_DIR:-${GITHUB_WORKSPACE:-${ci_workspace_dir:-}}}"
    local parsed_prefix_paths=''
    local prefix_path=''
    local cmake_variable='CMAKE_PREFIX_PATH'
    local cmake_prefix_path=''
    local android_java_dir=''
    local urho3d_dir=''
    local urho3d_prefix_path=''
    local toolchain_dir=''
    local candidate=''
    local bin_dir=''
    local executable_dir=''
    local -a prefix_paths=()
    local -a resolved_prefix_paths=()

    parsed_prefix_paths="$(parse-path-list "$prefix_paths_value")"
    if [[ -n "$parsed_prefix_paths" ]]; then
        mapfile -t prefix_paths <<< "$parsed_prefix_paths"
    fi

    for prefix_path in "${prefix_paths[@]}"; do
        if [[ "$prefix_path" != /* && ! "$prefix_path" =~ ^[A-Za-z]:[/\\] ]]; then
            prefix_path="${workspace_dir}/${prefix_path}"
        fi
        prefix_path=$(normalize-path "$prefix_path")
        if [[ ! -d "$prefix_path" ]]; then
            echo "Ignoring missing CMake prefix: $prefix_path"
            continue
        fi
        resolved_prefix_paths+=("$prefix_path")

        # Artifact transfer strips executable modes from host tools.
        if [[ "${RUNNER_OS:-}" != 'Windows' ]]; then
            for bin_dir in "$prefix_path/bin" "$prefix_path/Urho3D/bin"; do
                if [[ -d "$bin_dir" ]]; then
                    find "$bin_dir" -maxdepth 2 -type f ! -name '*.*' \
                        -exec chmod a+x {} +
                fi
            done
        fi

        if [[ -z "$android_java_dir" ]]; then
            for candidate in \
                "$prefix_path/Source/ThirdParty/SDL/android-project/app/src/main/java" \
                "$prefix_path/../Source/ThirdParty/SDL/android-project/app/src/main/java" \
                "$prefix_path/share/Urho3D/Android/java" \
                "$prefix_path/Urho3D/Android/java"; do
                candidate=$(normalize-path "$candidate")
                if [[ -d "$candidate" ]]; then
                    android_java_dir="$candidate"
                    break
                fi
            done
        fi
    done

    if [[ ${#resolved_prefix_paths[@]} -eq 0 ]]; then
        echo 'Error: cmake_prefix_path does not contain an existing directory.'
        return 1
    fi

    # Source packages are target packages. Installed packages retain caller order.
    for prefix_path in "${resolved_prefix_paths[@]}"; do
        candidate=$(normalize-path "$prefix_path/Urho3D/share/Urho3D")
        if [[ -f "$candidate/Urho3DConfig.cmake" ]]; then
            urho3d_dir="$candidate"
            urho3d_prefix_path="$prefix_path"
            break
        fi
    done
    if [[ -z "$urho3d_dir" ]]; then
        for prefix_path in "${resolved_prefix_paths[@]}"; do
            for candidate in \
                "$prefix_path/share/Urho3D/CMake" \
                "$prefix_path/Urho3D/CMake"; do
                candidate=$(normalize-path "$candidate")
                if [[ -f "$candidate/Urho3DConfig.cmake" ]]; then
                    urho3d_dir="$candidate"
                    urho3d_prefix_path="$prefix_path"
                    break 2
                fi
            done
        done
    fi

    for candidate in \
        "$urho3d_prefix_path/Toolchains" \
        "$urho3d_prefix_path/share/Urho3D/CMake/Toolchains" \
        "$urho3d_prefix_path/Urho3D/CMake/Toolchains"; do
        candidate=$(normalize-path "$candidate")
        if [[ -d "$candidate" ]]; then
            toolchain_dir="$candidate"
            break
        fi
    done

    cmake_prefix_path="$(IFS=';'; echo "${resolved_prefix_paths[*]}")"
    if [[ "$ci_platform" == 'web' ]]; then
        cmake_variable='CMAKE_FIND_ROOT_PATH'
    fi

    write-github-env CI_CMAKE_PREFIX_PATH "$cmake_prefix_path"
    write-github-env "$cmake_variable" "$cmake_prefix_path"
    write-github-env Urho3D_DIR "$urho3d_dir"
    write-github-env RBFX_TOOLCHAIN_DIR "$toolchain_dir"
    write-github-env RBFX_ANDROID_JAVA_DIR "$android_java_dir"
    write-github-output cmake_prefix_path "$cmake_prefix_path"
    write-github-output cmake_variable "$cmake_variable"
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

command=$1
shift
case "$command" in
    setup-environment) setup-environment "$@" ;;
    dependencies) install-dependencies "$@" ;;
    setup-emsdk) setup-emsdk "$@" ;;
    build-swig) build-swig "$@" ;;
    setup-package-tool) setup-package-tool "$@" ;;
    resolve-cmake-prefix-path) resolve-cmake-prefix-path "$@" ;;
    *)
        echo "Error: unknown preparation command: $command"
        usage
        exit 1
        ;;
esac
