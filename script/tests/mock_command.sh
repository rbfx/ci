#!/usr/bin/env bash
set -euo pipefail

command_name=$(basename "$0")
if [[ -n "${MOCK_COMMAND_LOG:-}" ]]; then
    {
        printf '%s' "$command_name"
        printf ' %q' "$@"
        printf '\n'
    } >> "$MOCK_COMMAND_LOG"
fi

case "$command_name" in
    ccache)
        if [[ "${1:-}" != '-s' ]]; then
            exec "$@"
        fi
        ;;
    cmake)
        if [[ " $* " == *' -P '* ]]; then
            printf '%s\n' "${MOCK_THIRDPARTY_HASH:-thirdparty-hash}"
        else
            if [[ "${1:-}" == '--install' ]]; then
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == '--prefix' ]]; then
                        mkdir -p "$2"
                        break
                    fi
                    shift
                done
            fi
            printf '%s\n' "${MOCK_CMAKE_OUTPUT:-Configured}"
        fi
        ;;
    gradle)
        if [[ "${1:-}" == 'wrapper' ]]; then
            cp "$0" ./gradlew
            chmod +x ./gradlew
        fi
        ;;
    gh)
        if [[ "${1:-}" == 'release' && "${2:-}" == 'download' ]]; then
            target_dir='.'
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == '--dir' ]]; then
                    target_dir=$2
                    break
                fi
                shift
            done
            cp "${MOCK_GH_DOWNLOAD_SOURCE:?}" "$target_dir/"
        elif [[ "${1:-}" == 'api' && "${2:-}" == *'/jobs?'* ]]; then
            cat "${MOCK_GH_JOBS_FILE:?}"
        elif [[ "${1:-}" == 'api' && "${2:-}" == *'/artifacts?'* ]]; then
            cat "${MOCK_GH_ARTIFACTS_FILE:?}"
        fi
        ;;
esac
