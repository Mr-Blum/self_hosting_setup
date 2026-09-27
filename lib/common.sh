#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# common.sh - shared helpers. Sourced, not executed.
# ---------------------------------------------------------------------------

# Resolve the repo root regardless of where a script was invoked from.
STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STACK_ROOT

# stack.env is resolved at runtime from STACK_ROOT, so shellcheck cannot
# follow it statically.
# shellcheck source=../config/stack.env disable=SC1091
. "${STACK_ROOT}/config/stack.env"

# --- Output ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

log()   { printf '%s==>%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()    { printf '%s  ok%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()   { printf '%s fail%s %s\n' "${C_RED}"   "${C_RESET}" "$*" >&2; }
dim()   { printf '%s     %s%s\n' "${C_DIM}"    "$*" "${C_RESET}"; }
die()   { err "$*"; exit 1; }

# --- Temp files -----------------------------------------------------------
# One temp dir per run, removed on exit. Do NOT use `trap ... RETURN` for
# per-function temp files: a RETURN trap in bash is not function-scoped, so it
# fires again on later returns when the function-local variable is gone, and
# under `set -u` that aborts the script after the work already succeeded.
STACK_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/stack.XXXXXX")"
# shellcheck disable=SC2317
_stack_cleanup() { rm -rf "${STACK_TMPDIR}"; }
trap _stack_cleanup EXIT

# Print a path for a run-scoped temp file with the given name.
stack_tmp() { printf '%s/%s\n' "${STACK_TMPDIR}" "$1"; }

# --- Preconditions --------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    local missing=()
    for c in "$@"; do have "$c" || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] || die "missing required command(s): ${missing[*]}"
}

# Refuse to run as root: OpenCode and its config belong to the real user.
# We escalate per-command via sudo instead.
refuse_root() {
    [ "$(id -u)" -ne 0 ] || die \
"do not run this as root.

Run it as your normal user; it will call sudo only for the steps that
need it (installing Ollama, writing the systemd override). Running the
whole script as root would install OpenCode and its config into /root."
}

# Run a command with root privileges, preferring an already-valid sudo ticket.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    else
        die "need root for: $* (and sudo is not installed)"
    fi
}

# Prompt once up front so later sudo calls don't interrupt a long install.
prime_sudo() {
    [ "$(id -u)" -eq 0 ] && return 0
    have sudo || die "sudo is required but not installed"
    if ! sudo -n true 2>/dev/null; then
        log "sudo access is needed to install Ollama and write its systemd override"
        sudo -v || die "could not obtain sudo privileges"
    fi
}

# --- Ollama helpers -------------------------------------------------------
# OLLAMA_BIND must be host:port. The systemd override feeds it to the server
# as a bind address, and we feed it to clients as a target, so a URL form
# would be wrong in one of those places. Fail fast rather than half-work.
case "${OLLAMA_BIND}" in
    http://*|https://*)
        die "OLLAMA_BIND must be host:port (e.g. 127.0.0.1:11434), not a URL: ${OLLAMA_BIND}"
        ;;
    *:*)
        # Valid host:port format - OK
        ;;
    *)
        # Missing port part 
        die "OLLAMA_BIND must include port (e.g. 127.0.0.1:11434), not just hostname: ${OLLAMA_BIND}"
        ;;
esac

# The `ollama` CLI resolves its target from OLLAMA_HOST, while our curl calls
# use OLLAMA_BIND. Left unlinked those diverge: pointing OLLAMA_BIND at another
# machine would send health checks to the remote box while every
# `ollama list/ps/pull` silently kept talking to localhost. Export one from the
# other so a single variable is authoritative for both.
# 
# Note: This only affects the current execution. A proper fix for persistent
# environment handling across shell sessions requires an updated bootstrap or
# additional coordination between scripts.
export OLLAMA_HOST="${OLLAMA_BIND}"

ollama_api() { printf 'http://%s' "${OLLAMA_BIND}"; }

# Block until the Ollama HTTP API answers, or time out.
wait_for_ollama() {
    local timeout="${1:-60}" waited=0
    log "waiting for Ollama API on ${OLLAMA_BIND} (timeout ${timeout}s)"
    while [ "${waited}" -lt "${timeout}" ]; do
        if curl -fsS --max-time 2 "$(ollama_api)/api/version" >/dev/null 2>&1; then
            ok "Ollama API is up$(curl -fsS "$(ollama_api)/api/version" 2>/dev/null \
                | sed -n 's/.*"version":"\([^"]*\)".*/ (v\1)/p')"
            return 0
        fi
        sleep 2; waited=$((waited + 2))
    done
    err "Ollama API did not come up within ${timeout}s"
    dim "check: systemctl status ollama && journalctl -u ollama -n 50 --no-pager"
    return 1
}

# True if the given model tag is already present locally.
model_present() {
    ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qxF "$1"
}

# --- OpenCode helpers -----------------------------------------------------
# The official installer hardcodes its install directory, so never assume a
# path: locate the binary. Prints the full path on success, nothing on failure.
find_opencode() {
    if have opencode; then
        command -v opencode
        return 0
    fi
    local d
    for d in "${OPENCODE_INSTALL_DIR}" "${HOME}/.opencode/bin" \
             "${HOME}/.local/bin" /usr/local/bin; do
        if [ -x "${d}/opencode" ]; then
            printf '%s\n' "${d}/opencode"
            return 0
        fi
    done
    return 1
}

# --- Config rendering -----------------------------------------------------
# Render a .tmpl file, substituting @NAME@ placeholders. Keeps one source of
# truth (stack.env) instead of duplicating values into committed JSON.
render_template() {
    local src="$1" dest="$2"
    [ -f "${src}" ] || die "template not found: ${src}"
    sed \
        -e "s|@PRIMARY_MODEL@|${PRIMARY_MODEL}|g" \
        -e "s|@SECONDARY_MODEL@|${SECONDARY_MODEL}|g" \
        -e "s|@OLLAMA_CTX@|${OLLAMA_CTX}|g" \
        -e "s|@OLLAMA_OUTPUT@|${OLLAMA_OUTPUT:-16384}|g" \
        -e "s|@OLLAMA_BIND@|${OLLAMA_BIND}|g" \
        -e "s|@OLLAMA_FLASH_ATTN@|${OLLAMA_FLASH_ATTN}|g" \
        -e "s|@OLLAMA_KV_CACHE@|${OLLAMA_KV_CACHE}|g" \
        -e "s|@OLLAMA_MAX_LOADED@|${OLLAMA_MAX_LOADED}|g" \
        -e "s|@OLLAMA_PARALLEL@|${OLLAMA_PARALLEL}|g" \
        -e "s|@OLLAMA_KEEPALIVE@|${OLLAMA_KEEPALIVE}|g" \
        -e "s|@OLLAMA_DISABLE_CLOUD@|${OLLAMA_DISABLE_CLOUD}|g" \
        "${src}" > "${dest}"
}

# Back up a file before overwriting, once per timestamp.
backup_file() {
    local f="$1"
    [ -f "${f}" ] || return 0
    local bak
    bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "${f}" "${bak}"
    warn "existing ${f} backed up to ${bak}"
}

# --- Misc -----------------------------------------------------------------
# Free space in GB on the filesystem holding $1.
free_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

human_gb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }

# Size of a directory in KiB. Falls back to sudo, since the model store is
# owned by the ollama user and unreadable to us.
dir_size_kb() {
    local d="$1" out
    out="$(du -sk "${d}" 2>/dev/null | awk '{print $1}')"
    if [ -z "${out}" ] && have sudo; then
        out="$(sudo -n du -sk "${d}" 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "${out}"
}

# Free space in KiB on the filesystem holding $1 (works for a path that does
# not exist yet by walking up to the nearest existing ancestor).
free_kb() {
    local d="$1"
    while [ -n "${d}" ] && [ ! -d "${d}" ]; do d="$(dirname "${d}")"; done
    [ -n "${d}" ] || d=/
    df -Pk "${d}" 2>/dev/null | awk 'NR==2{print $4}'
}

# Refuse to start a large copy that cannot finish. need_kb is padded by 5%.
require_space() {
    local target="$1" need_kb="$2" what="$3"
    [ -n "${need_kb}" ] && [ "${need_kb}" -gt 0 ] 2>/dev/null || return 0

    local avail_kb padded
    avail_kb="$(free_kb "${target}")"
    if [ -z "${avail_kb}" ]; then
        warn "cannot determine free space on ${target}; proceeding without a check"
        return 0
    fi
    padded=$(( need_kb + need_kb / 20 ))

    if [ "${avail_kb}" -lt "${padded}" ]; then
        die "not enough space for ${what}: need ~$(( padded / 1048576 ))GB (incl. 5% margin), have $(( avail_kb / 1048576 ))GB on ${target}"
    fi
    ok "space check (${what}): ~$(( padded / 1048576 ))GB needed, $(( avail_kb / 1048576 ))GB free"
}
