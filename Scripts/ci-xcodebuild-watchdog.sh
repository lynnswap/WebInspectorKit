#!/bin/bash

set -uo pipefail

stall_seconds="${STALL_SECONDS:-120}"
poll_seconds="${POLL_SECONDS:-1}"
resume_recheck_seconds="${RESUME_RECHECK_SECONDS:-5}"
sample_seconds="${SAMPLE_SECONDS:-5}"
simulator_udid="${WATCHDOG_SIMULATOR_UDID:-}"
diagnostics_dir="${WATCHDOG_DIAGNOSTICS_DIR:-}"
startup_sample_interval="${WATCHDOG_STARTUP_SAMPLE_INTERVAL_SECONDS:-60}"
startup_sample_pid=""
startup_sample_started=0
startup_sampling_finished=false
startup_last_log_size=0
command_started_seconds=${SECONDS}
log="$(mktemp -t ci-command-watchdog)"

if [ -n "${simulator_udid}" ] \
    && [[ ! "${simulator_udid}" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    echo "Invalid WATCHDOG_SIMULATOR_UDID: ${simulator_udid}" >&2
    exit 64
fi

cleanup() {
    local exit_code=$?
    stop_startup_sample
    record_startup_event watchdog_exit "status=${exit_code}"
    rm -f "${log}"
}
trap cleanup EXIT

"$@" > >(tee -a "${log}") 2>&1 &
runner=$!
command_started_seconds=${SECONDS}

diagnostics_warning() {
    echo "::warning::Startup diagnostics: $*" >&2
}

record_startup_event() {
    [ -n "${diagnostics_dir}" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$((SECONDS - command_started_seconds))" "$1" "${2:-}" \
        >> "${diagnostics_dir}/timeline.tsv" \
        || diagnostics_warning "could not write the timeline"
}

reap_startup_sample() {
    [ -n "${startup_sample_pid}" ] || return 0
    local status=0
    wait "${startup_sample_pid}" || status=$?
    startup_sample_pid=""
    record_startup_event sample_finished "status=${status}"
    if [ "${status}" -ne 0 ]; then
        diagnostics_warning "sample exited with status ${status}; see the startup artifact"
    fi
}

stop_startup_sample() {
    [ -n "${startup_sample_pid}" ] || return 0
    if kill -0 "${startup_sample_pid}" 2>/dev/null; then
        terminate_process_tree "${startup_sample_pid}"
        wait "${startup_sample_pid}" 2>/dev/null || true
        startup_sample_pid=""
        record_startup_event sample_stopped
    else
        reap_startup_sample
    fi
}

capture_startup_processes() {
    local label=$1
    local path="${diagnostics_dir}/processes-${label}.txt"
    {
        printf 'UTC=%s elapsed_s=%s xcodebuild_pid=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$((SECONDS - command_started_seconds))" "${runner}"
        ps -axo pid=,ppid=,etime=,stat=,pcpu=,comm=
    } > "${path}" 2>&1 || diagnostics_warning "could not capture processes in ${path}"
}

update_startup_diagnostics() {
    [ -n "${diagnostics_dir}" ] || return 0
    local size=$1
    local elapsed=$((SECONDS - command_started_seconds))
    local label

    if [ "${size}" -ne "${startup_last_log_size}" ]; then
        record_startup_event output "bytes=${size}"
        startup_last_log_size=${size}
    fi
    if [ "${startup_sampling_finished}" = true ]; then
        return 0
    fi
    if grep -Eq '(^Test Suite |^Test Case |Test run started[.]|Testing Library Version:)' "${log}"; then
        startup_sampling_finished=true
        record_startup_event tests_started "bytes=${size}"
        stop_startup_sample
        return 0
    fi
    if [ -n "${startup_sample_pid}" ]; then
        if ! kill -0 "${startup_sample_pid}" 2>/dev/null; then
            reap_startup_sample
        elif [ "$((elapsed - startup_sample_started))" -ge 5 ]; then
            diagnostics_warning "sample did not finish within five seconds; stopping only the diagnostic process"
            stop_startup_sample
        fi
    fi
    if [ "${elapsed}" -lt "${next_startup_sample}" ]; then
        return 0
    fi
    next_startup_sample=$((elapsed + startup_sample_interval))
    printf -v label '%06d' "${elapsed}"
    capture_startup_processes "${label}"
    if [ -z "${startup_sample_pid}" ] && kill -0 "${runner}" 2>/dev/null; then
        record_startup_event sample_started "pid=${runner} duration_s=1 file=sample-${label}.txt"
        sample "${runner}" 1 -mayDie > "${diagnostics_dir}/sample-${label}.txt" 2>&1 &
        startup_sample_pid=$!
        startup_sample_started=${elapsed}
    fi
}

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

terminate_process_tree() {
    local root_pid=$1
    local child_pid
    for child_pid in $(pgrep -P "${root_pid}" 2>/dev/null); do
        terminate_process_tree "${child_pid}"
    done
    kill -9 "${root_pid}" 2>/dev/null || true
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

shutdown_owned_simulator() {
    [ -n "${simulator_udid}" ] || return

    local shutdown_pid
    local timeout_seconds=5
    local remaining=${timeout_seconds}
    xcrun simctl shutdown "${simulator_udid}" >/dev/null 2>&1 &
    shutdown_pid=$!

    while kill -0 "${shutdown_pid}" 2>/dev/null && [ "${remaining}" -gt 0 ]; do
        sleep 1
        remaining=$((remaining - 1))
    done

    if kill -0 "${shutdown_pid}" 2>/dev/null; then
        echo "::warning::simulator shutdown did not finish within ${timeout_seconds}s; terminating simctl"
        terminate_process_tree "${shutdown_pid}"
    fi
    wait "${shutdown_pid}" 2>/dev/null || true
}

terminate_test_processes() {
    terminate_process_tree "${runner}"
    shutdown_owned_simulator
}

next_startup_sample=${startup_sample_interval}
if [ -n "${diagnostics_dir}" ]; then
    if mkdir -p "${diagnostics_dir}" \
        && printf 'utc\telapsed_s\tevent\tdetails\n' > "${diagnostics_dir}/timeline.tsv"; then
        record_startup_event command_started "pid=${runner} poll_interval_s=${poll_seconds}"
        capture_startup_processes 000000
    else
        diagnostics_warning "could not initialize ${diagnostics_dir}; continuing without startup diagnostics"
        diagnostics_dir=""
    fi
fi

last_size=-1
stalled_for=0
while kill -0 "${runner}" 2>/dev/null; do
    sleep "${poll_seconds}"
    size="$(log_size)"
    update_startup_diagnostics "${size}"
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

command_status=0
wait "${runner}" || command_status=$?
update_startup_diagnostics "$(log_size)"
record_startup_event command_finished "status=${command_status}"
exit "${command_status}"
