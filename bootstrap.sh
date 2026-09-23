#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap.sh - install and configure the local agentic coding stack.
#
#   Ollama (backend)  +  qwen3-coder / muse-glimmer (models)  +  OpenCode (agent)
#
# Safe to re-run: every step is idempotent and skips work already done.
# Requires a normal user account with sudo access. Do not run as root.
# ---------------------------------------------------------------------------
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

OFFLINE=0
DO_OLLAMA=1
DO_TUNE=1
DO_MODELS=1
DO_OPENCODE=1
DO_CONFIG=1
DO_VERIFY=1
BUNDLE_DIR=""

usage() {
    cat <<'EOF'
Usage: ./bootstrap.sh [options]

Installs Ollama, pulls the two coding models, installs OpenCode, and wires
them together for fully local operation.

Options:
  --offline DIR     Install from an airgap bundle directory instead of the
                    network (see bundle.sh / restore.sh).
  --skip-ollama     Assume Ollama is already installed.
  --skip-tune       Do not touch the systemd override.
  --skip-models     Do not pull models (~37GB).
  --skip-opencode   Do not install the OpenCode binary.
  --skip-config     Do not write ~/.config/opencode/opencode.json.
  --no-verify       Skip the post-install health checks.
  --only-config     Shorthand: only (re)write the OpenCode config.
  --only-tune       Shorthand: only re-apply the Ollama systemd tuning.
                    Use this after changing OLLAMA_CTX or OLLAMA_KV_CACHE.
  -h, --help        Show this help.

Environment overrides (see config/stack.env):
  OLLAMA_CTX=32768 ./bootstrap.sh      lower the context window
  OPENCODE_VERSION=v1.18.32 ./bootstrap.sh   pin the OpenCode release
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --offline)      OFFLINE=1; BUNDLE_DIR="${2:?--offline needs a directory}"; shift 2 ;;
        --skip-ollama)  DO_OLLAMA=0; shift ;;
        --skip-tune)    DO_TUNE=0; shift ;;
        --skip-models)  DO_MODELS=0; shift ;;
        --skip-opencode) DO_OPENCODE=0; shift ;;
        --skip-config)  DO_CONFIG=0; shift ;;
        --no-verify)    DO_VERIFY=0; shift ;;
        --only-config)  DO_OLLAMA=0; DO_TUNE=0; DO_MODELS=0; DO_OPENCODE=0; DO_VERIFY=0; shift ;;
        --only-tune)    DO_OLLAMA=0; DO_MODELS=0; DO_OPENCODE=0; DO_CONFIG=0; DO_VERIFY=0; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              err "unknown option: $1"; usage; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
preflight() {
    log "preflight checks"
    refuse_root
    require_cmd curl tar sed awk grep df

    if [ "${OFFLINE}" -eq 1 ]; then
        [ -d "${BUNDLE_DIR}" ] || die "bundle directory not found: ${BUNDLE_DIR}"
        ok "offline bundle: ${BUNDLE_DIR}"
    fi

    # GPU is not strictly required (Ollama falls back to CPU) but a CPU-only
    # run of a 30B model is unusably slow for an agentic loop, so warn loudly.
    if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        local gpu vram
        gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
        vram="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
        ok "GPU: ${gpu} (${vram} MiB)"
        if [ "${vram}" -lt 20000 ]; then
            warn "under 20GB of VRAM - a q4 30B model at ${OLLAMA_CTX} context will not fit."
            warn "lower OLLAMA_CTX or pick a smaller model before continuing."
        fi
    else
        warn "no working nvidia-smi found. Ollama will run on CPU, which is"
        warn "far too slow for agentic coding with a 30B model."
    fi

    if [ "${DO_MODELS}" -eq 1 ]; then
        local avail
        avail="$(free_gb /usr/share 2>/dev/null || free_gb / )"
        if [ -n "${avail}" ] && [ "${avail}" -lt 45 ]; then
            die "need ~45GB free for both models, found ${avail}GB"
        fi
        ok "disk space: ${avail}GB available"
    fi

    ensure_jq
}

# jq is not strictly required, but without it verify.sh cannot strictly
# validate tool-call JSON or the OpenCode config - which is most of its value.
ensure_jq() {
    if have jq; then
        ok "jq present"
        return 0
    fi
    if [ "${OFFLINE}" -eq 1 ]; then
        warn "jq not installed and we are offline; verification will be shallow"
        dim  "on the bundle machine: sudo apt-get install -y jq"
        return 0
    fi
    if have apt-get; then
        log "installing jq (needed for strict health checks)"
        prime_sudo
        if as_root apt-get install -y -q jq >/dev/null 2>&1; then
            ok "jq installed"
        else
            warn "could not install jq; verification will be shallow"
        fi
    else
        warn "jq not installed and no apt-get found; verification will be shallow"
    fi
}

# ---------------------------------------------------------------------------
# 1. Ollama
# ---------------------------------------------------------------------------
install_ollama() {
    if have ollama; then
        ok "Ollama already installed ($(ollama --version 2>/dev/null | head -1))"
        return 0
    fi

    log "installing Ollama"
    prime_sudo

    if [ "${OFFLINE}" -eq 1 ]; then
        local tgz="${BUNDLE_DIR}/ollama-linux-amd64.tgz"
        [ -f "${tgz}" ] || die "offline install needs ${tgz} (produced by bundle.sh)"
        log "extracting ${tgz} to /usr/local"
        as_root tar -C /usr/local -xzf "${tgz}"
        install_ollama_service_offline
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    have ollama || die "Ollama install did not put 'ollama' on PATH"
    ok "Ollama installed"
}

# The official install.sh creates the ollama user + systemd unit for us.
# In the offline path we extract a tarball, so we must do that ourselves.
install_ollama_service_offline() {
    if ! id ollama >/dev/null 2>&1; then
        log "creating ollama system user"
        as_root useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
    fi

    if [ ! -f /etc/systemd/system/ollama.service ]; then
        log "installing ollama.service"
        as_root tee /etc/systemd/system/ollama.service >/dev/null <<'UNIT'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    fi

    as_root systemctl daemon-reload
    as_root systemctl enable ollama
}

# ---------------------------------------------------------------------------
# 2. VRAM / context tuning
# ---------------------------------------------------------------------------
tune_ollama() {
    log "applying Ollama tuning (context=${OLLAMA_CTX}, kv=${OLLAMA_KV_CACHE}, max_loaded=${OLLAMA_MAX_LOADED})"

    local dropin_dir=/etc/systemd/system/ollama.service.d
    local dropin="${dropin_dir}/10-local-stack.conf"
    local tmp
    tmp="$(stack_tmp override.conf)"

    render_template "${STACK_ROOT}/config/ollama-override.conf.tmpl" "${tmp}"

    # The drop-in is world-readable (0644), so compare BEFORE escalating.
    # A re-run that changes nothing must not prompt for a sudo password.
    if [ -f "${dropin}" ] && cmp -s "${tmp}" "${dropin}"; then
        ok "systemd override already up to date"
    else
        prime_sudo
        as_root mkdir -p "${dropin_dir}"
        as_root cp "${tmp}" "${dropin}"
        as_root chmod 0644 "${dropin}"
        ok "wrote ${dropin}"
        as_root systemctl daemon-reload
        log "restarting ollama"
        as_root systemctl restart ollama
    fi

    # 'is-enabled' is an unprivileged query; only escalate if it must change.
    if ! systemctl is-enabled --quiet ollama 2>/dev/null; then
        prime_sudo
        as_root systemctl enable ollama
    fi
    wait_for_ollama 90
}

# ---------------------------------------------------------------------------
# 3. Models
# ---------------------------------------------------------------------------
pull_models() {
    log "ensuring models are present"
    wait_for_ollama 60

    if [ "${OFFLINE}" -eq 1 ]; then
        warn "offline mode: models come from the bundle, not 'ollama pull'."
        warn "run restore.sh to place model blobs before bootstrap, or pass --skip-models."
    fi

    local m
    for m in ${STACK_MODELS}; do
        if model_present "${m}"; then
            ok "${m} already present"
            continue
        fi
        if [ "${OFFLINE}" -eq 1 ]; then
            err "${m} is missing and cannot be pulled offline"
            dim "restore it with: ./restore.sh --bundle ${BUNDLE_DIR}"
            return 1
        fi
        log "pulling ${m} (this is ~19GB, expect a wait)"
        ollama pull "${m}"
        ok "pulled ${m}"
    done
}

# ---------------------------------------------------------------------------
# 4. OpenCode
# ---------------------------------------------------------------------------
install_opencode() {
    local oc_path
    if oc_path="$(find_opencode)"; then
        ok "OpenCode already installed ($("${oc_path}" --version 2>/dev/null | head -1)) at ${oc_path}"
        return 0
    fi

    log "installing OpenCode"

    if [ "${OFFLINE}" -eq 1 ]; then
        local tgz
        tgz="$(find "${BUNDLE_DIR}" -maxdepth 1 -name 'opencode-linux-x64*.tar.gz' | head -1)"
        [ -n "${tgz}" ] || die "offline install needs an opencode tarball in ${BUNDLE_DIR}"
        log "extracting $(basename "${tgz}") to ${OPENCODE_INSTALL_DIR}"
        mkdir -p "${OPENCODE_INSTALL_DIR}"
        tar -C "${OPENCODE_INSTALL_DIR}" -xzf "${tgz}"
        chmod +x "${OPENCODE_INSTALL_DIR}/opencode" 2>/dev/null || true
    else
        # Note: the official installer hardcodes $HOME/.opencode/bin and
        # honours no install-dir override, so we do not try to set one. It
        # also appends that directory to ~/.bashrc itself.
        [ -n "${OPENCODE_VERSION}" ] && export OPENCODE_VERSION
        curl -fsSL https://opencode.ai/install | bash
    fi

    if ! oc_path="$(find_opencode)"; then
        die "OpenCode install finished but no binary was found"
    fi
    ok "OpenCode installed at ${oc_path}"

    if ! have opencode; then
        warn "not on PATH in this shell yet - open a new terminal or:"
        dim  "  source ~/.bashrc"
    fi
}

# ---------------------------------------------------------------------------
# 5. OpenCode config
# ---------------------------------------------------------------------------
write_opencode_config() {
    local dest="${OPENCODE_CONFIG_DIR}/opencode.json"
    log "writing ${dest}"
    mkdir -p "${OPENCODE_CONFIG_DIR}"

    local tmp
    tmp="$(stack_tmp opencode.json)"
    render_template "${STACK_ROOT}/config/opencode.json.tmpl" "${tmp}"

    # Validate before installing so we never leave a broken config behind.
    if have jq; then
        jq empty "${tmp}" 2>/dev/null || die "rendered config is not valid JSON"
    elif have node; then
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "${tmp}" \
            || die "rendered config is not valid JSON"
    else
        warn "neither jq nor node available; skipping JSON validation"
    fi

    if [ -f "${dest}" ] && cmp -s "${tmp}" "${dest}"; then
        ok "config already up to date"
        return 0
    fi

    backup_file "${dest}"
    cp "${tmp}" "${dest}"
    ok "config written (default model: ${PRIMARY_MODEL})"
}

# ---------------------------------------------------------------------------
main() {
    preflight
    if [ "${DO_OLLAMA}"   -eq 1 ]; then install_ollama;        fi
    if [ "${DO_TUNE}"     -eq 1 ]; then tune_ollama;           fi
    if [ "${DO_MODELS}"   -eq 1 ]; then pull_models;           fi
    if [ "${DO_OPENCODE}" -eq 1 ]; then install_opencode;      fi
    if [ "${DO_CONFIG}"   -eq 1 ]; then write_opencode_config; fi

    echo
    if [ "${DO_VERIFY}" -eq 1 ]; then
        log "running health checks"
        "${STACK_ROOT}/verify.sh" || die "verification failed - see output above"
    fi

    echo
    ok "stack ready"
    dim "start coding:      cd your-project && opencode"
    dim "switch models:     /models inside the TUI"
    dim "check VRAM fit:    ./verify.sh"
}

main "$@"
