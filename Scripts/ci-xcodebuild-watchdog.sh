#!/bin/bash

set -uo pipefail

stall_seconds="${STALL_SECONDS:-120}"
poll_seconds="${POLL_SECONDS:-1}"
resume_recheck_seconds="${RESUME_RECHECK_SECONDS:-5}"
sample_seconds="${SAMPLE_SECONDS:-5}"
log="$(mktemp -t ci-command-watchdog)"

cleanup() {
    rm -f "${log}"
}
trap cleanup EXIT

"$@" > >(tee -a "${log}") 2>&1 &
runner=$!

log_size() {
    stat -f%z "${log}" 2>/dev/null || echo 0
}

sample_process() {
    local pid=$1
    local command
    command="$(ps -o comm= -p "${pid}" 2>/dev/null)"
    [ -n "${command}" ] || return

    echo "===== sample of pid ${pid} (${command}) ====="
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo sample "${pid}" "${sample_seconds}" -mayDie 2>&1 || true
    else
        sample "${pid}" "${sample_seconds}" -mayDie 2>&1 || true
    fi
}

wait_for_output_or_exit() {
    local stalled_size=$1
    local remaining=${resume_recheck_seconds}
    local size

    while [ "${remaining}" -gt 0 ]; do
        sleep 1
        if ! kill -0 "${runner}" 2>/dev/null; then
            return 0
        fi
        size="$(log_size)"
        if [ "${size}" -ne "${stalled_size}" ]; then
            stalled_for=0
            last_size="${size}"
            return 0
        fi
        remaining=$((remaining - 1))
    done
    return 1
}

descendant_process_ids() {
    local root_pid=$1
    local child_pid
    for child_pid in $(pgrep -P "${root_pid}" 2>/dev/null); do
        descendant_process_ids "${child_pid}"
        echo "${child_pid}"
    done
}

dump_stall_diagnostics() {
    echo "::error::xcodebuild produced no output for ${stall_seconds}s; dumping process state"

    local pid
    for pid in $(descendant_process_ids "${runner}"); do
        sample_process "${pid}"
    done
    sample_process "${runner}"
}

terminate_test_processes() {
    terminate_process_tree "${runner}"
}

terminate_process_tree() {
    local root_pid=$1
    local child_pid
    for child_pid in $(pgrep -P "${root_pid}" 2>/dev/null); do
        terminate_process_tree "${child_pid}"
    done
    kill -9 "${root_pid}" 2>/dev/null || true
}

last_size=-1
stalled_for=0
while kill -0 "${runner}" 2>/dev/null; do
    sleep "${poll_seconds}"
    size="$(log_size)"
    if [ "${size}" -eq "${last_size}" ]; then
        stalled_for=$((stalled_for + poll_seconds))
    else
        stalled_for=0
        last_size=${size}
    fi

    if [ "${stalled_for}" -lt "${stall_seconds}" ]; then
        continue
    fi

    stalled_size="${size}"
    if wait_for_output_or_exit "${stalled_size}"; then
        continue
    fi

    dump_stall_diagnostics
    if ! kill -0 "${runner}" 2>/dev/null; then
        break
    fi
    if wait_for_output_or_exit "${stalled_size}"; then
        echo "::warning::xcodebuild output resumed while diagnostics were collected; continuing"
        continue
    fi

    terminate_test_processes
    exit 70
done

wait "${runner}"
