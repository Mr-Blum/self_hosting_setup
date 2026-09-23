#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# model.sh - inspect and switch the resident model from outside OpenCode.
#
# Inside an OpenCode session you switch with /models, which is usually what
# you want. This is for the surrounding workflow: preloading a model before
# you start so the first prompt is not stuck behind a 30s load, freeing the
# GPU for other work, and seeing what is actually resident.
# ---------------------------------------------------------------------------
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    cat <<EOF
Usage: ./model.sh <command> [model]

Commands:
  list              Show managed models and which is resident
  status            Show 'ollama ps' plus live GPU memory
  load [model]      Preload a model into VRAM (default: ${PRIMARY_MODEL})
  primary           Preload ${PRIMARY_MODEL}
  secondary         Preload ${SECONDARY_MODEL}
  stop [model]      Unload a model (default: all managed models)
  free              Unload everything, freeing the GPU

Managed models:
  primary:   ${PRIMARY_MODEL}
  secondary: ${SECONDARY_MODEL}

Only one of these fits in 24GB at a time; loading one evicts the other.
EOF
}

# Expand the friendly aliases to real tags.
resolve() {
    case "${1:-}" in
        primary|"")  printf '%s' "${PRIMARY_MODEL}" ;;
        secondary)   printf '%s' "${SECONDARY_MODEL}" ;;
        *)           printf '%s' "$1" ;;
    esac
}

gpu_line() {
    have nvidia-smi || return 0
    local used total
    used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
    total="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
    dim "GPU: ${used} / ${total} MiB used"
}

cmd_list() {
    local resident m
    resident="$(ollama ps 2>/dev/null | awk 'NR>1{print $1}')"
    for m in ${STACK_MODELS}; do
        local mark="  " state="on disk"
        model_present "${m}" || state="NOT PULLED"
        if printf '%s\n' "${resident}" | grep -qxF "${m}"; then
            mark="* "; state="resident in VRAM"
        fi
        printf '%s%-34s %s\n' "${mark}" "${m}" "${state}"
    done
    gpu_line
}

cmd_status() {
    ollama ps
    gpu_line
}

cmd_load() {
    local target
    target="$(resolve "${1:-primary}")"
    model_present "${target}" || die "${target} is not pulled (ollama pull ${target})"

    # Evict the others first so we never attempt a co-load on a 24GB card.
    local m
    for m in ${STACK_MODELS}; do
        if [ "${m}" != "${target}" ]; then
            ollama stop "${m}" >/dev/null 2>&1 || true
        fi
    done

    log "loading ${target} at ${OLLAMA_CTX} context"
    curl -fsS --max-time 300 "$(ollama_api)/api/generate" \
        -d "$(printf '{"model":"%s","prompt":"","keep_alive":"%s"}' \
              "${target}" "${OLLAMA_KEEPALIVE}")" >/dev/null \
        || die "failed to load ${target}"

    local line proc
    line="$(ollama ps 2>/dev/null | awk -v m="${target}" '$1==m')"
    proc="$(printf '%s\n' "${line}" | grep -oE '[0-9]+%/[0-9]+% CPU/GPU|100% GPU|100% CPU' | head -1)"
    if [ "${proc}" = "100% GPU" ]; then
        ok "${target} resident, 100% GPU"
    else
        warn "${target} resident but ${proc:-unknown placement} - expect heavy slowdown"
        dim "see README 'if a model does not fit' for the remedy ladder"
    fi
    gpu_line
}

cmd_stop() {
    if [ $# -eq 0 ]; then
        local m
        for m in ${STACK_MODELS}; do
            if ollama stop "${m}" >/dev/null 2>&1; then
                ok "stopped ${m}"
            fi
        done
    else
        local t
        t="$(resolve "$1")"
        ollama stop "${t}" && ok "stopped ${t}"
    fi
    gpu_line
}

# Handle help before dependency checks so `--help` works on a bare machine.
case "${1:-list}" in
    -h|--help|help) usage; exit 0 ;;
esac

require_cmd ollama curl

case "${1:-list}" in
    list)      cmd_list ;;
    status)    cmd_status ;;
    load)      shift; cmd_load "${1:-primary}" ;;
    primary)   cmd_load primary ;;
    secondary) cmd_load secondary ;;
    stop)      shift; cmd_stop "$@" ;;
    free)      cmd_stop ;;
    *)         err "unknown command: $1"; usage; exit 2 ;;
esac
