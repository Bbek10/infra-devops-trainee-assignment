#!/usr/bin/env bash
# infra_health_check.sh
# checks cpu, memory, root disk and the docker app container
# warns if disk goes over the threshold or the app container isn't running
# exit 0 = fine, 1 = warning, 2 = something missing

set -euo pipefail

# cron runs with almost no PATH so docker won't be found unless we set it here
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# defaults, can be overridden from the environment for testing
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
APP_CONTAINER="${APP_CONTAINER:-infra_app}"
LOG_FILE="${LOG_FILE:-/var/log/infra_health.log}"

warnings=0

trap 'printf "[ERROR] unexpected failure at line %s\n" "$LINENO" >&2' ERR

timestamp() { date '+%Y-%m-%d %H:%M:%S%z'; }

# don't let a bad log path kill the whole run
log() {
    printf '%s %s\n' "$(timestamp)" "$1" >> "$LOG_FILE" 2>/dev/null \
        || printf '[ERROR] cannot write to %s\n' "$LOG_FILE" >&2
}

warn() {
    printf '[WARNING] %s\n' "$1"
    log "[WARNING] $1"
    warnings=$(( warnings + 1 ))
}

info() { printf '[INFO]    %s\n' "$1"; }

cpu_usage() {
    # the numbers in /proc/stat add up since boot, so reading it once just
    # gives the average since the machine started. take two samples a second
    # apart and work out the difference instead
    local a b total_a idle_a total_b idle_b
    a=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
    sleep 1
    b=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
    total_a=${a% *}; idle_a=${a#* }
    total_b=${b% *}; idle_b=${b#* }
    awk -v ta="$total_a" -v ia="$idle_a" -v tb="$total_b" -v ib="$idle_b" \
        'BEGIN { dt = tb - ta; di = ib - ia;
                 if (dt <= 0) printf "0.0"; else printf "%.1f", (dt - di) * 100 / dt }'
}

mem_usage() {
    # using MemAvailable, not "free". free ignores cache that the kernel can
    # reclaim, so it makes the box look busier than it is
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
         END { if (t > 0) printf "%.1f", (t - a) * 100 / t; else printf "0.0" }' /proc/meminfo
}

disk_usage() {
    # -P keeps df on one line, otherwise long device names wrap and awk
    # picks up the wrong column
    df -P / | awk 'NR==2 { gsub(/%/, "", $5); print $5 }'
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        warn "docker command not found on PATH"
        return 2
    fi
    # docker info actually talks to the daemon, unlike docker --version
    if ! docker info >/dev/null 2>&1; then
        warn "Docker daemon is not responding"
        return 1
    fi
    info "Docker daemon    : running"
    return 0
}

check_container() {
    local state
    # inspect fails outright if the container was never created, so handle
    # that separately from it existing but being stopped
    if ! state=$(docker inspect -f '{{.State.Status}}' "$APP_CONTAINER" 2>/dev/null); then
        warn "application container '${APP_CONTAINER}' does not exist"
        return 1
    fi
    if [[ "$state" != "running" ]]; then
        warn "application container '${APP_CONTAINER}' is ${state}"
        return 1
    fi
    info "App container    : ${APP_CONTAINER} running"
    return 0
}

main() {
    local cpu mem disk
    cpu=$(cpu_usage)
    mem=$(mem_usage)
    disk=$(disk_usage)

    printf '=== infra health check - %s ===\n' "$(timestamp)"
    info "CPU usage        : ${cpu}%"
    info "Memory usage     : ${mem}%"
    info "Root disk usage  : ${disk}% (threshold ${DISK_THRESHOLD}%)"

    if (( disk > DISK_THRESHOLD )); then
        warn "root filesystem at ${disk}%, over the ${DISK_THRESHOLD}% threshold"
    fi

    # no point checking the container if the daemon is down
    if check_docker; then
        check_container || true
    fi

    if (( warnings > 0 )); then
        printf '\n%d warning(s) written to %s\n' "$warnings" "$LOG_FILE"
        exit 1
    fi

    printf '\nAll checks passed.\n'
    exit 0
}

main "$@"
