#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
system_path=$PATH

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert-contains() {
    local file=$1
    local pattern=$2
    grep -F -- "$pattern" "$file" >/dev/null || fail "$file does not contain: $pattern"
}

reset-command-log() {
    : > "$MOCK_COMMAND_LOG"
}

mock_bin="$temp_dir/bin"
mkdir -p "$mock_bin"
for command_name in cmake ccache ctest dotnet gradle gh butler; do
    ln -s "$repo_root/script/tests/mock_command.sh" "$mock_bin/$command_name"
done
export PATH="$mock_bin:$PATH"
export MOCK_COMMAND_LOG="$temp_dir/commands.log"
: > "$MOCK_COMMAND_LOG"

test-setup-environment() {
    reset-command-log
    local github_env="$temp_dir/setup.env"
    ci_platform_tag=linux-gcc-x64-dll \
    ci_profile=downstream \
    GITHUB_SHA=1234567890abcdef \
    GITHUB_ENV="$github_env" \
        "$repo_root/script/ci_prepare.sh" setup-environment
    assert-contains "$github_env" 'ci_platform=linux'
    assert-contains "$github_env" 'ci_short_sha=12345678'
    assert-contains "$github_env" 'ci_platform_group=desktop'

    if ci_platform_tag=linux-gcc-arm64-dll \
        ci_profile=downstream \
        GITHUB_ENV="$temp_dir/invalid.env" \
        "$repo_root/script/ci_prepare.sh" setup-environment >/dev/null 2>&1; then
        fail 'unsupported platform tag was accepted'
    fi
}

test-generate-engine() {
    reset-command-log
    local workspace="$temp_dir/generate"
    mkdir -p "$workspace/source" "$workspace/build" "$workspace/sdk"
    local github_output="$workspace/output"
    ci_platform=linux \
    ci_arch=x64 \
    ci_compiler=clang \
    ci_lib_type=dll \
    ci_platform_group=desktop \
    ci_platform_tag=linux-clang-x64-dll \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build" \
    ci_sdk_dir="$workspace/sdk" \
    ci_build_types='{"dbg":"Debug","rel":"RelWithDebInfo"}' \
    GITHUB_OUTPUT="$github_output" \
    RUNNER_TEMP="$workspace" \
        "$repo_root/script/ci_build.sh" generate-engine \
            -- -DTEST_VALUE=ON

    assert-contains "$MOCK_COMMAND_LOG" 'cmake --preset linux-clang-x64-dll'
    assert-contains "$MOCK_COMMAND_LOG" '-DURHO3D_PCH=OFF'
    assert-contains "$MOCK_COMMAND_LOG" '-DTEST_VALUE=ON'
    assert-contains "$github_output" 'thirdparty_used=true'
}

test-downstream-linux-build() {
    reset-command-log
    local workspace="$temp_dir/linux-project"
    mkdir -p "$workspace/source" "$workspace/build" "$workspace/install" "$workspace/sdk"
    ci_platform=linux \
    ci_arch=x64 \
    ci_compiler=gcc \
    ci_lib_type=dll \
    ci_platform_tag=linux-gcc-x64-dll \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build" \
    ci_sdk_dir="$workspace/sdk" \
    ci_build_types='{"asan":"ASan"}' \
    CI_CMAKE_PREFIX_PATH="$workspace/sdk" \
        "$repo_root/script/ci_build.sh" build-project \
            --build-dir "$workspace/build" \
            --install-dir "$workspace/install" \
            "$workspace/source" \
            -- -DPROJECT_TEST=ON

    assert-contains "$MOCK_COMMAND_LOG" '-DCMAKE_CONFIGURATION_TYPES=ASan'
    assert-contains "$MOCK_COMMAND_LOG" 'cmake --build'
    assert-contains "$MOCK_COMMAND_LOG" '--config ASan'
    assert-contains "$MOCK_COMMAND_LOG" 'cmake --install'
}

test-downstream-android-custom-task() {
    reset-command-log
    local workspace="$temp_dir/android-project"
    mkdir -p "$workspace/source/android" "$workspace/build" "$workspace/sdk"
    ci_platform=android \
    ci_arch=arm64 \
    ci_compiler=clang \
    ci_lib_type=dll \
    ci_platform_tag=android-clang-arm64-dll \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build" \
    ci_sdk_dir="$workspace/sdk" \
    ci_build_types='{"benchmark":"bundleBenchmark"}' \
    CI_CMAKE_PREFIX_PATH="$workspace/sdk" \
        "$repo_root/script/ci_build.sh" build-android-project "$workspace/source/android"

    assert-contains "$MOCK_COMMAND_LOG" 'gradlew bundleBenchmark'
}

test-engine-sdk-install() {
    reset-command-log
    local workspace="$temp_dir/install"
    mkdir -p "$workspace/source" "$workspace/build" "$workspace/sdk"
    ci_platform=linux \
    ci_arch=x64 \
    ci_compiler=gcc \
    ci_lib_type=dll \
    ci_platform_tag=linux-gcc-x64-dll \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build" \
    ci_sdk_dir="$workspace/sdk" \
    ci_hash_thirdparty=expected-thirdparty \
    ci_build_types='{"dbg":"Debug","rel":"RelWithDebInfo"}' \
        "$repo_root/script/ci_build.sh" install-engine-sdk

    assert-contains "$MOCK_COMMAND_LOG" '--component ThirdParty'
    assert-contains "$MOCK_COMMAND_LOG" '--config RelWithDebInfo'
    assert-contains "$workspace/sdk/thirdparty-id.txt" 'expected-thirdparty'
    [[ -f "$workspace/sdk/thirdparty-files.txt" ]] \
        || fail 'ThirdParty file manifest was not created'
}

test-custom-android-engine-sdk-install() {
    reset-command-log
    local workspace="$temp_dir/android-install"
    local cmake_build_dir="$workspace/source/android/.cxx/generated/by/gradle"
    mkdir -p \
        "$workspace/source/android/.cxx/tools/debug/helper" \
        "$workspace/build" \
        "$workspace/sdk"
    PATH="$system_path" cmake \
        -S "$repo_root/script/tests/fixtures/minimal-project" \
        -B "$cmake_build_dir" \
        -DCMAKE_BUILD_TYPE=Benchmark \
        >/dev/null

    ci_platform=android \
    ci_arch=arm64 \
    ci_compiler=clang \
    ci_lib_type=dll \
    ci_platform_tag=android-clang-arm64-dll \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build" \
    ci_sdk_dir="$workspace/sdk" \
    ci_hash_thirdparty=expected-thirdparty \
    ci_build_types='{"benchmark":"bundleBenchmark"}' \
        "$repo_root/script/ci_build.sh" install-engine-sdk

    assert-contains "$MOCK_COMMAND_LOG" "cmake --install $cmake_build_dir"
    assert-contains "$MOCK_COMMAND_LOG" '--component ThirdParty'
    if grep -F -- '.cxx/tools/debug' "$MOCK_COMMAND_LOG" >/dev/null; then
        fail 'Android tools directory was treated as an install tree'
    fi
    if grep -F -- '--config' "$MOCK_COMMAND_LOG" >/dev/null; then
        fail 'Android CMake configuration was inferred from its build path'
    fi
}

test-platform-cmake-arguments() {
    reset-command-log
    local workspace="$temp_dir/platform-arguments"
    mkdir -p "$workspace/source" "$workspace/build" "$workspace/sdk" "$workspace/toolchains"
    touch "$workspace/toolchains/IOS.cmake"

    ci_platform=windows \
    ci_arch=x86 \
    ci_compiler=msvc \
    ci_lib_type=dll \
    ci_platform_tag=windows-msvc-x86-dll \
    ci_number_of_processors=2 \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build/windows" \
    ci_sdk_dir="$workspace/sdk" \
    ci_build_types='{"dbg":"Debug"}' \
        "$repo_root/script/ci_build.sh" build-project "$workspace/source"
    assert-contains "$MOCK_COMMAND_LOG" "-A Win32"

    ci_platform=web \
    ci_arch=wasm \
    ci_compiler=emscripten \
    ci_lib_type=lib \
    ci_platform_tag=web-emscripten-wasm-lib \
    ci_number_of_processors=2 \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build/web" \
    ci_sdk_dir="$workspace/sdk" \
    ci_build_types='{"dbg":"Debug"}' \
    EMSDK="$workspace/emsdk" \
        "$repo_root/script/ci_build.sh" build-project "$workspace/source"
    assert-contains "$MOCK_COMMAND_LOG" '-DURHO3D_PACKAGING=ON'
    assert-contains "$MOCK_COMMAND_LOG" '-DCMAKE_FIND_ROOT_PATH='
    assert-contains "$MOCK_COMMAND_LOG" 'Emscripten.cmake'

    ci_platform=ios \
    ci_arch=arm64 \
    ci_compiler=clang \
    ci_lib_type=lib \
    ci_platform_tag=ios-clang-arm64-lib \
    ci_number_of_processors=2 \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build/ios" \
    ci_sdk_dir="$workspace/sdk" \
    ci_build_types='{"dbg":"Debug"}' \
    RBFX_TOOLCHAIN_DIR="$workspace/toolchains" \
        "$repo_root/script/ci_build.sh" build-project "$workspace/source"
    assert-contains "$MOCK_COMMAND_LOG" '-DPLATFORM=OS64'
    assert-contains "$MOCK_COMMAND_LOG" 'IOS.cmake'
}

test-prefix-resolution() {
    reset-command-log
    local workspace="$temp_dir/prefixes"
    local host="$workspace/host"
    local source="$workspace/source"
    mkdir -p \
        "$host/share/Urho3D/CMake" \
        "$source/Urho3D/share/Urho3D" \
        "$source/Toolchains" \
        "$host/bin"
    touch \
        "$host/share/Urho3D/CMake/Urho3DConfig.cmake" \
        "$source/Urho3D/share/Urho3D/Urho3DConfig.cmake" \
        "$source/Toolchains/IOS.cmake" \
        "$host/bin/PackageTool"
    chmod 644 "$host/bin/PackageTool"

    local github_env="$workspace/env"
    local github_output="$workspace/output"
    ci_platform=linux \
    INPUT_WORKSPACE_DIR="$workspace" \
    INPUT_CMAKE_PREFIX_PATH=$'host\nsource' \
    GITHUB_ENV="$github_env" \
    GITHUB_OUTPUT="$github_output" \
        "$repo_root/script/ci_prepare.sh" resolve-cmake-prefix-path

    assert-contains "$github_env" "Urho3D_DIR=$source/Urho3D/share/Urho3D"
    assert-contains "$github_env" "RBFX_TOOLCHAIN_DIR=$source/Toolchains"
    [[ -x "$host/bin/PackageTool" ]] || fail 'artifact executable mode was not restored'
}

test-cache-id-mismatch() {
    reset-command-log
    local workspace="$temp_dir/cache"
    local asset_name='rebelfork-sdk-linux-gcc-x64-dll-latest'
    mkdir -p "$workspace/archive/$asset_name"
    printf 'cached-id\n' > "$workspace/archive/$asset_name/thirdparty-id.txt"
    (
        cd "$workspace/archive"
        7z a "$workspace/$asset_name.7z" "$asset_name" >/dev/null
    )

    if ci_platform_tag=linux-gcc-x64-dll \
        ci_workspace_dir="$workspace" \
        ci_hash_thirdparty=expected-id \
        GH_TOKEN=test \
        GITHUB_REPOSITORY=rbfx/rbfx \
        GITHUB_OUTPUT="$workspace/output" \
        MOCK_GH_DOWNLOAD_SOURCE="$workspace/$asset_name.7z" \
        "$repo_root/script/ci_artifacts.sh" download-cached-sdk >/dev/null 2>&1; then
        fail 'mismatched ThirdParty cache ID was accepted'
    fi
    assert-contains "$workspace/output" 'sdk_cached=false'
}

test-wait-for-build() {
    reset-command-log
    local workspace="$temp_dir/wait"
    mkdir -p "$workspace"
    printf 'native-job\tcompleted\tsuccess\t2026-01-01T00:00:00Z\t2026-01-01T00:01:00Z\n' > "$workspace/jobs"
    printf 'native-artifact\t42\t2026-01-01T00:00:30Z\n' > "$workspace/artifacts"
    local github_output="$workspace/output"
    MOCK_GH_JOBS_FILE="$workspace/jobs" \
    MOCK_GH_ARTIFACTS_FILE="$workspace/artifacts" \
    INPUT_JOB_NAME=native-job \
    INPUT_ARTIFACT_NAMES=native-artifact \
    INPUT_TIMEOUT_SECONDS=2 \
    INPUT_ARTIFACT_GRACE_SECONDS=60 \
    INPUT_REPOSITORY=rbfx/sample-project \
    INPUT_RUN_ID=1 \
    INPUT_RUN_ATTEMPT=1 \
    CI_WAIT_POLL_SECONDS=0 \
    GITHUB_OUTPUT="$github_output" \
        "$repo_root/script/ci_wait_for_build.sh"
    assert-contains "$github_output" 'artifact_ids=42'

    printf 'native-job\tcompleted\tfailure\t2026-01-01T00:00:00Z\t2026-01-01T00:01:00Z\n' > "$workspace/jobs"
    if MOCK_GH_JOBS_FILE="$workspace/jobs" \
        MOCK_GH_ARTIFACTS_FILE="$workspace/artifacts" \
        INPUT_JOB_NAME=native-job \
        INPUT_TIMEOUT_SECONDS=2 \
        INPUT_REPOSITORY=rbfx/sample-project \
        INPUT_RUN_ID=1 \
        CI_WAIT_POLL_SECONDS=0 \
        "$repo_root/script/ci_wait_for_build.sh" >/dev/null 2>&1; then
        fail 'failed producer job was accepted'
    fi

    printf 'native-job\tcompleted\tsuccess\t2026-01-01T00:00:00Z\t2026-01-01T00:01:00Z\n' > "$workspace/jobs"
    printf 'native-artifact\t42\t2026-01-01T00:00:30Z\nnative-artifact\t43\t2026-01-01T00:00:40Z\n' > "$workspace/artifacts"
    if MOCK_GH_JOBS_FILE="$workspace/jobs" \
        MOCK_GH_ARTIFACTS_FILE="$workspace/artifacts" \
        INPUT_JOB_NAME=native-job \
        INPUT_ARTIFACT_NAMES=native-artifact \
        INPUT_TIMEOUT_SECONDS=2 \
        INPUT_REPOSITORY=rbfx/sample-project \
        INPUT_RUN_ID=1 \
        CI_WAIT_POLL_SECONDS=0 \
        "$repo_root/script/ci_wait_for_build.sh" >/dev/null 2>&1; then
        fail 'ambiguous run artifacts were accepted'
    fi

    if MOCK_GH_JOBS_FILE="$workspace/missing-jobs" \
        MOCK_GH_ARTIFACTS_FILE="$workspace/artifacts" \
        INPUT_JOB_NAME=native-job \
        INPUT_TIMEOUT_SECONDS=2 \
        INPUT_REPOSITORY=rbfx/sample-project \
        INPUT_RUN_ID=1 \
        CI_WAIT_POLL_SECONDS=0 \
        "$repo_root/script/ci_wait_for_build.sh" >/dev/null 2>&1; then
        fail 'GitHub API failure was ignored'
    fi
}

test-real-linux-project() {
    reset-command-log
    local workspace="$temp_dir/real-linux-project"
    local integration_bin="$workspace/bin"
    mkdir -p "$integration_bin" "$workspace/sdk"
    ln -s "$repo_root/script/tests/mock_command.sh" "$integration_bin/ccache"

    PATH="$integration_bin:$system_path" \
    MOCK_COMMAND_LOG="$workspace/commands.log" \
    ci_platform=linux \
    ci_arch=x64 \
    ci_compiler=gcc \
    ci_lib_type=lib \
    ci_platform_tag=linux-gcc-x64-lib \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$repo_root/script/tests/fixtures/minimal-project" \
    ci_build_dir="$workspace/build" \
    ci_sdk_dir="$workspace/sdk" \
    ci_build_types='{"dbg":"Debug"}' \
        "$repo_root/script/ci_build.sh" build-project \
            --build-dir "$workspace/build" \
            --install-dir "$workspace/install" \
            "$repo_root/script/tests/fixtures/minimal-project"

    [[ -x "$workspace/install/bin/ci-script-smoke" ]] \
        || fail 'real downstream build did not install its executable'
}

test-default-build-types-run-sequentially() {
    reset-command-log
    local workspace="$temp_dir/default-build-types"
    mkdir -p "$workspace/source" "$workspace/build" "$workspace/sdk"

    ci_platform=linux \
    ci_arch=x64 \
    ci_compiler=gcc \
    ci_lib_type=lib \
    ci_platform_tag=linux-gcc-x64-lib \
    ci_number_of_processors=2 \
    ci_workspace_dir="$workspace" \
    ci_source_dir="$workspace/source" \
    ci_build_dir="$workspace/build" \
    ci_sdk_dir="$workspace/sdk" \
        "$repo_root/script/ci_build.sh" build-project \
            --build-dir "$workspace/build" \
            "$workspace/source"

    mapfile -t build_commands < <(
        grep -F 'cmake --build' "$MOCK_COMMAND_LOG"
    )
    [[ ${#build_commands[@]} -eq 2 ]] \
        || fail 'default build types did not produce exactly two builds'
    [[ "${build_commands[0]}" == *'--config Debug'* ]] \
        || fail 'Debug was not built first'
    [[ "${build_commands[1]}" == *'--config RelWithDebInfo'* ]] \
        || fail 'RelWithDebInfo was not built second'
}

test-caller-audit() {
    local removed_pattern='generate-detect-thirdparty|build-configurations|test-configurations|cstest-configurations|extract-sdk-archive|download-release| action-apk| apk'
    local -a audit_paths=(
        "$repo_root/.github"
        "$repo_root/script/ci_build.sh"
        "$repo_root/script/ci_prepare.sh"
        "$repo_root/script/ci_artifacts.sh"
        "$repo_root/script/ci_wait_for_build.sh"
    )
    if [[ -d "$repo_root/../rbfx/.github/workflows" ]]; then
        audit_paths+=("$repo_root/../rbfx/.github/workflows")
    fi
    if rg -n "$removed_pattern" "${audit_paths[@]}"; then
        fail 'removed CI command is still referenced'
    fi
}

test-setup-environment
test-generate-engine
test-downstream-linux-build
test-downstream-android-custom-task
test-engine-sdk-install
test-custom-android-engine-sdk-install
test-platform-cmake-arguments
test-prefix-resolution
test-cache-id-mismatch
test-wait-for-build
test-real-linux-project
test-default-build-types-run-sequentially
test-caller-audit
echo 'All CI script tests passed.'
