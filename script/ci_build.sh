#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci_common.sh
source "$script_dir/ci_common.sh"

usage() {
    echo "Usage: $0 <command> [options] [-- extra-cmake-args]"
    echo "Commands:"
    echo "  generate-engine       Generate the engine and report ThirdParty reuse"
    echo "  build-engine          Build all selected engine configurations"
    echo "  test-engine-native    Run native tests for selected configurations"
    echo "  test-engine-managed   Run managed tests for selected configurations"
    echo "  install-engine-sdk    Install the complete engine SDK"
    echo "  test-project          Configure/test an engine consumer"
    echo "  build-project         Configure/build/install a downstream CMake project"
    echo "  build-android-project Build a downstream Android Gradle project"
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi
ci_action=$1
shift

declare -a arg_extra=()
declare -a arg_positional=()
arg_build_dir=''
arg_install_dir=''

parse-args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)
                shift
                arg_extra=("$@")
                return
                ;;
            --build-dir|--install-dir)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "Error: $1 requires an argument"
                    return 1
                fi
                local variable="arg_${1#--}"
                variable=${variable//-/_}
                printf -v "$variable" '%s' "$2"
                shift 2
                ;;
            --*)
                echo "Error: unsupported option: $1"
                return 1
                ;;
            *)
                arg_positional+=("$1")
                shift
                ;;
        esac
    done
}
parse-args "$@"

declare -a configured_build_type_ids=()
declare -A configured_build_type_names=()
load-build-types() {
    local build_types="${ci_build_types:-}"
    if [[ -z "$build_types" ]]; then
        build_types=$(
            python3 "$script_dir/ci_data.py" \
                default-build-types "$ci_platform"
        )
    fi

    local parsed_build_types=''
    if ! parsed_build_types=$(
        python3 "$script_dir/ci_data.py" \
            build-types-tsv \
            "$build_types"
    ); then
        return 1
    fi

    local build_type=''
    local build_type_name=''
    while IFS=$'\t' read -r build_type build_type_name; do
        configured_build_type_ids+=("$build_type")
        configured_build_type_names["$build_type"]="$build_type_name"
    done <<< "$parsed_build_types"
    if [[ ${#configured_build_type_ids[@]} -eq 0 ]]; then
        echo "Error: ci_build_types did not define a usable build type"
        return 1
    fi
}

initialize-build-context() {
    local variable=''
    for variable in ci_workspace_dir ci_source_dir ci_build_dir ci_sdk_dir; do
        if [[ -n "${!variable:-}" ]]; then
            printf -v "$variable" '%s' "$(normalize-path "${!variable}")"
        fi
    done
    if [[ -n "${ci_source_dir:-}" ]]; then
        ci_source_dir=${ci_source_dir%/}
    fi
    if [[ -z "${ci_number_of_processors:-}" ]]; then
        detect-processor-count
    fi
    load-build-types

}

get-cmake-configuration-types() {
    local result=''
    local build_type=''
    for build_type in "${configured_build_type_ids[@]}"; do
        if [[ -n "$result" ]]; then
            result+=';'
        fi
        result+="${configured_build_type_names[$build_type]}"
    done
    printf '%s\n' "$result"
}

get-sdk-share-suffix() {
    if [[ "$ci_platform" == 'windows' || "$ci_platform" == 'uwp' ]]; then
        printf '/share\n'
    fi
}

run-gradle-task() {
    local project_dir=$1
    shift
    cd "$project_dir"
    if [[ ! -f ./gradlew ]]; then
        gradle wrapper
    fi
    chmod +x ./gradlew
    ./gradlew "$@"
}

run-engine-android-task() {
    local task=$1
    ccache -s
    run-gradle-task "$ci_source_dir/android" "$task"
    ccache -s
}

generate-engine() {
    local cmake_prefix_path='CMAKE_PREFIX_PATH'
    if [[ "$ci_platform" == 'web' ]]; then
        cmake_prefix_path='CMAKE_FIND_ROOT_PATH'
    fi
    local sdk_suffix=''
    sdk_suffix=$(get-sdk-share-suffix)
    sdk_suffix=${sdk_suffix#/}

    local pch='ON'
    if [[ "$ci_platform" == 'linux' && "$ci_compiler" == 'clang' ]]; then
        pch='OFF'
    fi

    local -a cmake_params=(
        --preset "${ci_platform}-${ci_compiler}-${ci_arch}-${ci_lib_type}"
        -B "$ci_build_dir"
        -S "$ci_source_dir"
        "-DCMAKE_INSTALL_PREFIX=$ci_sdk_dir"
        "-DCMAKE_CONFIGURATION_TYPES=$(get-cmake-configuration-types)"
        "-D${cmake_prefix_path}=${ci_workspace_dir}/cached-sdk/${sdk_suffix}"
        -DTRACY_TIMER_FALLBACK=ON
        "-DURHO3D_PCH=$pch"
    )
    if [[ "$ci_compiler" != 'msvc' ]]; then
        cmake_params+=(
            -DCMAKE_C_COMPILER_LAUNCHER=ccache
            -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
        )
    fi
    if [[ -n "${BUTLER_API_KEY:-}" ]]; then
        cmake_params+=(-DURHO3D_COPY_DATA_DIRS=ON)
    fi
    cmake_params+=("${arg_extra[@]}")

    printf 'cmake'
    printf ' %q' "${cmake_params[@]}"
    printf '\n'

    local generate_log
    generate_log=$(mktemp "${RUNNER_TEMP:-/tmp}/rbfx-generate.XXXXXX")
    if ! (set -o pipefail; cmake "${cmake_params[@]}" 2>&1 | tee "$generate_log"); then
        rm -f "$generate_log"
        return 1
    fi
    if grep -q 'Could NOT find Urho3DThirdParty' "$generate_log"; then
        echo "ThirdParty will be built from source"
        write-github-output thirdparty_used false
    else
        echo "Using cached Urho3DThirdParty"
        write-github-output thirdparty_used true
    fi
    rm -f "$generate_log"
}

build-msvc-configuration() {
    local configuration=$1
    local ccache_path
    ccache_path=$(realpath /c/ProgramData/chocolatey/lib/ccache/tools/ccache-*)
    cp "$ccache_path/ccache.exe" "$ccache_path/cl.exe"
    "$ccache_path/ccache.exe" -s
    cmake --build "$ci_build_dir" --config "$configuration" -- \
        -r "-maxcpucount:$ci_number_of_processors" \
        -p:TrackFileAccess=false \
        -p:UseMultiToolTask=true \
        "-p:CLToolPath=$ccache_path" \
        '-p:ObjectFileName=$(IntDir)%(FileName).obj' \
        -p:DebugInformationFormat=OldStyle
    "$ccache_path/ccache.exe" -s
}

build-engine() {
    local build_type=''
    for build_type in "${configured_build_type_ids[@]}"; do
        local configuration="${configured_build_type_names[$build_type]}"
        echo "Building configuration $configuration"
        if [[ "$ci_platform" == 'android' ]]; then
            run-engine-android-task "$configuration"
        elif [[ "$ci_compiler" == 'msvc' ]]; then
            build-msvc-configuration "$configuration"
        else
            ccache -s
            cmake --build "$ci_build_dir" \
                --parallel "$ci_number_of_processors" \
                --config "$configuration"
            ccache -s
        fi
    done
}

install-build-artifacts() {
    local build_type=$1
    shift
    local configuration="${configured_build_type_names[$build_type]}"
    cmake --install "$ci_build_dir" --config "$configuration" "$@"

    if [[ "$ci_platform" == 'windows' ]]; then
        copy-runtime-libraries-for-executables "$ci_sdk_dir/bin"
    fi
}

install-android-build-artifacts() {
    local cxx_root="$ci_source_dir/android/.cxx"
    local -a install_dirs=()
    if [[ -d "$cxx_root" ]]; then
        mapfile -t install_dirs < <(
            find "$cxx_root" \
                -type f \
                -name CMakeCache.txt \
                -printf '%h\n' \
                | sort
        )
    fi
    if [[ ${#install_dirs[@]} -eq 0 ]]; then
        echo "Error: no Android CMake build directories found under $cxx_root"
        return 1
    fi

    local install_dir=''
    for install_dir in "${install_dirs[@]}"; do
        cmake --install "$install_dir" "$@"
    done
}

install-engine-sdk() {
    local install_prefix="$ci_sdk_dir"
    local build_type=''
    if [[ "$ci_platform" == 'android' ]]; then
        install-android-build-artifacts \
            --component ThirdParty \
            --prefix "$install_prefix"
    else
        for build_type in "${configured_build_type_ids[@]}"; do
            install-build-artifacts "$build_type" \
                --component ThirdParty \
                --prefix "$install_prefix"
        done
    fi
    printf '%s\n' "${ci_hash_thirdparty:-}" > "$install_prefix/thirdparty-id.txt"
    (
        cd "$install_prefix"
        find . -type f | sed 's|^\./||' > thirdparty-files.txt
    )
    if [[ "$ci_platform" == 'android' ]]; then
        install-android-build-artifacts --prefix "$install_prefix"
    else
        for build_type in "${configured_build_type_ids[@]}"; do
            install-build-artifacts "$build_type" --prefix "$install_prefix"
        done
    fi

    if [[ "$ci_platform" == 'web' ]]; then
        local configuration=''
        for build_type in "${configured_build_type_ids[@]}"; do
            local candidate="${configured_build_type_names[$build_type]}"
            if [[ -f "$ci_sdk_dir/bin/$candidate/Samples.html" ]]; then
                configuration="$candidate"
            fi
        done
        if [[ -z "$configuration" ]]; then
            return
        fi
        mkdir -p "$ci_sdk_dir/deploy"
        cp -r \
            "$ci_sdk_dir/bin/$configuration/SampleResources.js" \
            "$ci_sdk_dir/bin/$configuration/SampleResources.js.data" \
            "$ci_sdk_dir/bin/$configuration/Samples.js" \
            "$ci_sdk_dir/bin/$configuration/Samples.wasm" \
            "$ci_sdk_dir/bin/$configuration/Samples.html" \
            "$ci_sdk_dir/deploy/"
    fi
}

test-engine-native() {
    local build_type=''
    for build_type in "${configured_build_type_ids[@]}"; do
        (
            cd "$ci_build_dir"
            ctest --output-on-failure \
                -C "${configured_build_type_names[$build_type]}" \
                -j "$ci_number_of_processors"
        )
    done
}

test-engine-managed() {
    local build_type=''
    for build_type in "${configured_build_type_ids[@]}"; do
        local test_dir="$ci_build_dir/bin/${configured_build_type_names[$build_type]}"
        if [[ -f "$test_dir/Urho3DNet.Tests.dll" ]]; then
            (
                cd "$test_dir"
                dotnet test Urho3DNet.Tests.dll
            )
        fi
    done
}

prepare-project-search-paths() {
    project_cmake_prefix_variable='CMAKE_PREFIX_PATH'
    project_cmake_prefix_value="${CI_CMAKE_PREFIX_PATH:-}"
    project_urho3d_dir="${Urho3D_DIR:-}"
    project_toolchain_dir="${RBFX_TOOLCHAIN_DIR:-}"
    if [[ "$ci_platform" == 'web' ]]; then
        project_cmake_prefix_variable='CMAKE_FIND_ROOT_PATH'
    fi
}

prepare-project-cmake-args() {
    local source_dir=$1
    local build_dir=$2
    local shared='OFF'
    if [[ "$ci_lib_type" == 'dll' ]]; then
        shared='ON'
    fi
    prepare-project-search-paths
    project_cmake_args=(
        -S "$source_dir"
        -B "$build_dir"
        "-DBUILD_SHARED_LIBS=$shared"
        "-DCMAKE_CONFIGURATION_TYPES=$(get-cmake-configuration-types)"
        "-D${project_cmake_prefix_variable}=${project_cmake_prefix_value}"
    )
    if [[ -n "$project_urho3d_dir" ]]; then
        project_cmake_args+=("-DUrho3D_DIR=$project_urho3d_dir")
    fi
    if [[ "$ci_platform" == 'web' || "$ci_platform" == 'ios' ]]; then
        project_cmake_args+=(-DURHO3D_PACKAGING=ON)
    fi

    case "$ci_platform" in
        windows|uwp)
            local generator_arch='x64'
            if [[ "$ci_arch" == 'x86' ]]; then
                generator_arch='Win32'
            fi
            project_cmake_args+=(-G 'Visual Studio 18 2026' -A "$generator_arch")
            if [[ "$ci_platform" == 'uwp' ]]; then
                project_cmake_args+=(
                    -DCMAKE_SYSTEM_NAME=WindowsStore
                    -DCMAKE_SYSTEM_VERSION=10.0
                )
            fi
            ;;
        linux)
            case "$ci_compiler" in
                gcc)
                    export CC=gcc
                    export CXX=g++
                    ;;
                clang)
                    export CC=clang
                    export CXX=clang++
                    ;;
            esac
            project_cmake_args+=(
                -G 'Ninja Multi-Config'
                -DCMAKE_C_COMPILER_LAUNCHER=ccache
                -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
            )
            ;;
        web)
            project_cmake_args+=(
                -G 'Ninja Multi-Config'
                "-DCMAKE_TOOLCHAIN_FILE=$EMSDK/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake"
                "-DEMSCRIPTEN_ROOT_PATH=$EMSDK/upstream/emscripten/"
                -DCMAKE_C_COMPILER_LAUNCHER=ccache
                -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
            )
            ;;
        ios)
            project_cmake_args+=(
                -G Xcode
                "-DCMAKE_TOOLCHAIN_FILE=$project_toolchain_dir/IOS.cmake"
                -DDEPLOYMENT_TARGET=12
                -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
            )
            case "$ci_arch" in
                arm) project_cmake_args+=(-DPLATFORM=OS) ;;
                arm64) project_cmake_args+=(-DPLATFORM=OS64) ;;
            esac
            ;;
        macos)
            project_cmake_args+=(-G Xcode)
            case "$ci_arch" in
                x64) project_cmake_args+=(-DCMAKE_OSX_ARCHITECTURES=x86_64) ;;
                arm64) project_cmake_args+=(-DCMAKE_OSX_ARCHITECTURES=arm64) ;;
            esac
            ;;
    esac
    project_cmake_args+=("${arg_extra[@]}")
}

configure-project() {
    local source_dir=$1
    local build_dir=$2
    local message=$3
    prepare-project-cmake-args "$source_dir" "$build_dir"
    echo "$message"
    printf 'cmake'
    printf ' %q' "${project_cmake_args[@]}"
    printf '\n'
    cmake "${project_cmake_args[@]}"
}

build-project-configurations() {
    local build_dir=$1
    local build_type=''
    for build_type in "${configured_build_type_ids[@]}"; do
        cmake --build "$build_dir" \
            --config "${configured_build_type_names[$build_type]}" \
            --parallel "$ci_number_of_processors"
    done
}

install-project-configurations() {
    local build_dir=$1
    local install_dir=$2
    local build_type=''
    for build_type in "${configured_build_type_ids[@]}"; do
        cmake --install "$build_dir" \
            --config "${configured_build_type_names[$build_type]}" \
            --prefix "$install_dir"
    done
}

test-project() {
    if [[ ${#arg_positional[@]} -ne 2 ]]; then
        echo "Error: test-project requires <project_name> <sdk|source>"
        return 1
    fi
    local project_name="${arg_positional[0]}"
    local mode="${arg_positional[1]}"
    if [[ "$mode" != 'sdk' && "$mode" != 'source' ]]; then
        echo "Error: test-project mode must be sdk or source"
        return 1
    fi

    local source_dir="$ci_workspace_dir/$project_name"
    local build_dir="$ci_workspace_dir/${project_name}-${mode}-build"
    if [[ "$mode" == 'sdk' ]]; then
        CI_CMAKE_PREFIX_PATH="${ci_sdk_dir}$(get-sdk-share-suffix)"
    else
        CI_CMAKE_PREFIX_PATH="$ci_source_dir/CMake"
    fi
    configure-project "$source_dir" "$build_dir" \
        "Configuring $project_name with configured CMake prefixes..."
    if [[ "$mode" == 'sdk' ]]; then
        build-project-configurations "$build_dir"
    else
        echo "Skipping source-mode build; configuration validates source consumption."
    fi
}

build-project() {
    if [[ ${#arg_positional[@]} -ne 1 ]]; then
        echo "Error: build-project requires <project_dir>"
        return 1
    fi
    if [[ "$ci_platform" == 'android' ]]; then
        echo "Error: use build-android-project for Android"
        return 1
    fi

    local source_dir
    source_dir=$(normalize-path "${arg_positional[0]}")
    local build_dir
    build_dir=$(normalize-path "${arg_build_dir:-$ci_workspace_dir/project-build/$ci_platform_tag}")
    local install_dir=''
    if [[ -n "$arg_install_dir" ]]; then
        install_dir=$(normalize-path "$arg_install_dir")
    fi
    configure-project "$source_dir" "$build_dir" \
        "Configuring downstream project from $source_dir"
    build-project-configurations "$build_dir"
    if [[ -n "$install_dir" ]]; then
        install-project-configurations "$build_dir" "$install_dir"
    fi
}

build-android-project() {
    if [[ ${#arg_positional[@]} -ne 1 ]]; then
        echo "Error: build-android-project requires <android_dir>"
        return 1
    fi
    if [[ "$ci_platform" != 'android' ]]; then
        echo "Error: build-android-project requires the Android platform"
        return 1
    fi

    local android_dir
    android_dir=$(normalize-path "${arg_positional[0]}")
    if [[ ! -d "$android_dir" ]]; then
        echo "Error: Android directory does not exist: $android_dir"
        return 1
    fi

    prepare-project-search-paths
    echo "Using ${project_cmake_prefix_variable}=${project_cmake_prefix_value}"
    export CMAKE_PREFIX_PATH="$project_cmake_prefix_value"
    if [[ -n "$project_urho3d_dir" ]]; then
        export Urho3D_DIR="$project_urho3d_dir"
    else
        unset Urho3D_DIR
    fi
    if [[ -n "${PACKAGE_TOOL_EXECUTABLE:-}" ]]; then
        echo "Using PackageTool executable: $PACKAGE_TOOL_EXECUTABLE"
    fi

    local build_type=''
    for build_type in "${configured_build_type_ids[@]}"; do
        run-gradle-task "$android_dir" "${configured_build_type_names[$build_type]}"
    done
}

case "$ci_action" in
    generate-engine|build-engine|test-engine-native|test-engine-managed|\
    install-engine-sdk|test-project|build-project|build-android-project)
        initialize-build-context
        ;;
    *)
        echo "Error: unknown build command: $ci_action"
        usage
        exit 1
        ;;
esac

case "$ci_action" in
    generate-engine) generate-engine ;;
    build-engine) build-engine ;;
    test-engine-native) test-engine-native ;;
    test-engine-managed) test-engine-managed ;;
    install-engine-sdk) install-engine-sdk ;;
    test-project) test-project ;;
    build-project) build-project ;;
    build-android-project) build-android-project ;;
esac
