#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ci_common.sh
source "$script_dir/ci_common.sh"

job_name="${INPUT_JOB_NAME:-}"
artifact_names_value="${INPUT_ARTIFACT_NAMES:-}"
timeout_seconds="${INPUT_TIMEOUT_SECONDS:-3600}"
artifact_grace_seconds="${INPUT_ARTIFACT_GRACE_SECONDS:-60}"
repository="${INPUT_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
run_id="${INPUT_RUN_ID:-${GITHUB_RUN_ID:-}}"
run_attempt="${INPUT_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}"
poll_seconds="${CI_WAIT_POLL_SECONDS:-15}"

if [[ -z "$job_name" ]]; then
    echo 'Error: INPUT_JOB_NAME is required.'
    exit 1
fi
if [[ -z "$repository" || -z "$run_id" ]]; then
    echo 'Error: repository and workflow run ID are required.'
    exit 1
fi
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Error: INPUT_TIMEOUT_SECONDS must be a positive integer.'
    exit 1
fi
if [[ ! "$artifact_grace_seconds" =~ ^[0-9]+$ ]]; then
    echo 'Error: INPUT_ARTIFACT_GRACE_SECONDS must be a non-negative integer.'
    exit 1
fi
parsed_artifact_names=''
parsed_artifact_names=$(parse-string-list "$artifact_names_value")
declare -a artifact_names=()
if [[ -n "$parsed_artifact_names" ]]; then
    mapfile -t artifact_names <<< "$parsed_artifact_names"
fi

job_status=''
job_conclusion=''
job_started_at=''
job_completed_at=''
find-job() {
    local job_data=''
    local job_row=''
    job_status=''
    job_conclusion=''
    job_started_at=''
    job_completed_at=''
    job_data=$(
        gh api "/repos/${repository}/actions/runs/${run_id}/attempts/${run_attempt}/jobs?per_page=100" \
            --paginate \
            --jq '.jobs[] | [.name, .status, (.conclusion // ""), (.started_at // ""), (.completed_at // "")] | @tsv'
    )
    job_row=$(awk -F '\t' -v name="$job_name" '$1 == name { print; exit }' <<< "$job_data")
    if [[ -n "$job_row" ]]; then
        IFS=$'\t' read -r _ job_status job_conclusion job_started_at job_completed_at <<< "$job_row"
    fi
}

declare -a artifact_ids=()
declare -a missing_artifact_names=()
find-artifacts() {
    local artifact_data=''
    local artifact_name=''
    local artifact_id=''
    local -a matching_artifact_ids=()
    artifact_ids=()
    missing_artifact_names=()
    artifact_data=$(
        gh api "/repos/${repository}/actions/runs/${run_id}/artifacts?per_page=100" \
            --paginate \
            --jq '.artifacts[] | select(.expired == false) | [.name, (.id | tostring), .created_at] | @tsv'
    )
    for artifact_name in "${artifact_names[@]}"; do
        matching_artifact_ids=()
        mapfile -t matching_artifact_ids < <(
            awk -F '\t' -v name="$artifact_name" -v started="$job_started_at" \
                '$1 == name && $3 >= started { print $2 }' <<< "$artifact_data"
        )
        if [[ ${#matching_artifact_ids[@]} -gt 1 ]]; then
            echo "Error: multiple run artifacts match '$artifact_name'; artifact names must be unique."
            return 1
        fi
        artifact_id="${matching_artifact_ids[0]:-}"
        if [[ -n "$artifact_id" ]]; then
            artifact_ids+=("$artifact_id")
        else
            missing_artifact_names+=("$artifact_name")
        fi
    done
}

deadline=$((SECONDS + timeout_seconds))
artifact_deadline=''
while [[ $SECONDS -lt $deadline ]]; do
    find-job
    if [[ -z "$job_status" ]]; then
        echo "Waiting for workflow job to appear: $job_name"
        sleep "$poll_seconds"
        continue
    fi
    if [[ "$job_status" != 'completed' ]]; then
        echo "Waiting for workflow job: $job_name ($job_status)"
        sleep "$poll_seconds"
        continue
    fi
    if [[ "$job_conclusion" != 'success' ]]; then
        echo "Error: workflow job '$job_name' completed with conclusion '$job_conclusion'."
        exit 1
    fi

    if [[ ${#artifact_names[@]} -eq 0 ]]; then
        write-github-output conclusion "$job_conclusion"
        write-github-output completed_at "$job_completed_at"
        exit 0
    fi

    find-artifacts
    if [[ ${#missing_artifact_names[@]} -eq 0 ]]; then
        write-github-output conclusion "$job_conclusion"
        write-github-output completed_at "$job_completed_at"
        write-github-output artifact_ids "$(IFS=,; echo "${artifact_ids[*]}")"
        exit 0
    fi

    if [[ -z "$artifact_deadline" ]]; then
        completed_epoch=$(
            python3 "$script_dir/ci_data.py" \
                iso-to-epoch "$job_completed_at" 2>/dev/null || true
        )
        if [[ -n "$completed_epoch" ]]; then
            artifact_deadline=$((completed_epoch + artifact_grace_seconds))
        else
            artifact_deadline=$(($(date +%s) + artifact_grace_seconds))
        fi
    fi
    if [[ $(date +%s) -ge $artifact_deadline ]]; then
        echo "Error: workflow job '$job_name' succeeded, but artifacts were not available within ${artifact_grace_seconds}s: ${missing_artifact_names[*]}"
        exit 1
    fi

    echo "Waiting for artifacts from '$job_name': ${missing_artifact_names[*]}"
    sleep "$poll_seconds"
done

echo "Error: timed out waiting for workflow job '$job_name' after ${timeout_seconds}s."
exit 1
