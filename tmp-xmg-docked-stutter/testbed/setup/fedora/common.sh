# shellcheck shell=bash disable=SC2034
# Shared helpers for the Fedora test-bed scripts. Sourced, not run.
# DRYRUN=1 prints every command that would change the system instead of running it.
set -euo pipefail

DRYRUN=${DRYRUN:-}
log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() { if [ -n "$DRYRUN" ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
srun() { run sudo "$@"; }

# Write stdin to a root-owned file (shown instead of written in dry-run mode).
write_root_file() {
    local path=$1 content
    content=$(cat)
    if [ -n "$DRYRUN" ]; then
        printf '[dry-run] write %s:\n%s\n' "$path" "$content"
    else
        printf '%s\n' "$content" | sudo tee "$path" >/dev/null
    fi
}

require_fedora() {
    local id='' ver=''
    if [ -n "${SETUP_ASSUME_FEDORA:-}" ]; then
        id=fedora; ver=$SETUP_ASSUME_FEDORA
    elif [ -r /etc/os-release ]; then
        id=$(. /etc/os-release && echo "${ID:-}")
        ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
    fi
    [ "$id" = fedora ] || die "this script is for Fedora (found '${id:-unknown}')"
    FEDORA=$ver
}

# SETUP_ETC / SETUP_MODULES / SETUP_ALLOW_ROOT exist for the test suite only.
ETC=${SETUP_ETC:-/etc}
[ "$(id -u)" != 0 ] || [ -n "${SETUP_ALLOW_ROOT:-}" ] || die "run as your normal user; the script calls sudo where needed"
