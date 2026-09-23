#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore.sh - install the stack on an airgapped machine from a bundle.
#
# Performs zero network access. Everything comes from the bundle directory
# produced by bundle.sh on a connected machine.
#
# Order matters: model blobs must be in place and owned by the ollama user
# before the service starts, otherwise Ollama will not see them.
# ---------------------------------------------------------------------------
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

BUNDLE=""
DO_MODELS=1

usage() {
    cat <<'EOF'
Usage: ./restore.sh --bundle DIR [options]

Options:
  --bundle DIR    Path to the bundle produced by bundle.sh (required)
  --no-models     Do not copy model blobs
  -h, --help      Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)    BUNDLE="${2:?--bundle needs a directory}"; shift 2 ;;
        --no-models) DO_MODELS=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           err "unknown option: $1"; usage; exit 2 ;;
    esac
done

[ -n "${BUNDLE}" ] || { usage; die "--bundle is required"; }
BUNDLE="$(cd "${BUNDLE}" && pwd)"

refuse_root
require_cmd tar

log "restoring from ${BUNDLE}"
[ -f "${BUNDLE}/MANIFEST.txt" ] && dim "$(grep -E '^(opencode_version|ollama_version|models):' \
    "${BUNDLE}/MANIFEST.txt" | tr '\n' ' ')"

prime_sudo

# ---------------------------------------------------------------------------
# 1. Verify checksums before installing anything
# ---------------------------------------------------------------------------
verify_checksums() {
    local manifest="${BUNDLE}/MANIFEST.txt"
    if [ ! -f "${manifest}" ] || ! have sha256sum; then
        warn "skipping checksum verification (no manifest or sha256sum)"
        return 0
    fi
    log "verifying bundle checksums"
    local sums
    sums="$(sed -n '/^## sha256/,/^$/p' "${manifest}" | grep -E '^[0-9a-f]{64}  ' || true)"
    if [ -z "${sums}" ]; then
        warn "no checksums in manifest"
        return 0
    fi
    if ( cd "${BUNDLE}" && printf '%s\n' "${sums}" | sha256sum -c --quiet ) 2>/dev/null; then
        ok "checksums match"
    else
        die "bundle checksum mismatch - the transfer may be corrupt"
    fi
}

# ---------------------------------------------------------------------------
# 2. Ollama runtime + service
# ---------------------------------------------------------------------------
install_ollama_offline() {
    if have ollama; then
        ok "Ollama already installed"
    else
        local tgz="${BUNDLE}/ollama-linux-amd64.tgz"
        [ -f "${tgz}" ] || die "missing ${tgz}"
        log "extracting Ollama runtime to /usr/local"
        as_root tar -C /usr/local -xzf "${tgz}"
        have ollama || die "ollama still not on PATH after extraction"
        ok "Ollama runtime installed"
    fi

    if ! id ollama >/dev/null 2>&1; then
        log "creating ollama system user"
        as_root useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
        ok "ollama user created"
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
        as_root systemctl daemon-reload
        as_root systemctl enable ollama
        ok "service installed"
    fi
}

# ---------------------------------------------------------------------------
# 3. Model blobs
# ---------------------------------------------------------------------------
restore_models() {
    if [ "${DO_MODELS}" -eq 0 ]; then
        warn "skipping model restore (--no-models)"
        return 0
    fi

    local src="${BUNDLE}/models"
    if [ ! -d "${src}" ]; then
        warn "no models directory in bundle; nothing to restore"
        return 0
    fi

    log "restoring model store to ${OLLAMA_MODELS_DIR}"
    as_root mkdir -p "${OLLAMA_MODELS_DIR}"

    if have rsync; then
        as_root rsync -a --info=progress2 "${src}/" "${OLLAMA_MODELS_DIR}/"
    else
        as_root cp -a "${src}/." "${OLLAMA_MODELS_DIR}/"
    fi

    # Ollama runs as the 'ollama' user and will silently fail to see blobs
    # it cannot read. This chown is the step people most often forget.
    log "fixing ownership for the ollama user"
    as_root chown -R ollama:ollama "$(dirname "${OLLAMA_MODELS_DIR}")"
    ok "model store restored"
}

# ---------------------------------------------------------------------------
# 4. OpenCode
# ---------------------------------------------------------------------------
install_opencode_offline() {
    if have opencode; then
        ok "OpenCode already installed"
        return 0
    fi
    local tgz
    tgz="$(find "${BUNDLE}" -maxdepth 1 -name 'opencode-linux-x64*.tar.gz' | head -1)"
    [ -n "${tgz}" ] || die "no opencode tarball found in ${BUNDLE}"

    log "extracting $(basename "${tgz}") to ${OPENCODE_INSTALL_DIR}"
    mkdir -p "${OPENCODE_INSTALL_DIR}"
    tar -C "${OPENCODE_INSTALL_DIR}" -xzf "${tgz}"
    chmod +x "${OPENCODE_INSTALL_DIR}/opencode" 2>/dev/null || true
    ok "OpenCode installed"

    case ":${PATH}:" in
        *":${OPENCODE_INSTALL_DIR}:"*) ;;
        *)
            warn "${OPENCODE_INSTALL_DIR} is not on your PATH; add to ~/.bashrc:"
            dim  "export PATH=\"${OPENCODE_INSTALL_DIR}:\$PATH\""
            ;;
    esac
}

# ---------------------------------------------------------------------------
main() {
    verify_checksums
    install_ollama_offline
    restore_models
    install_opencode_offline

    # Hand off to bootstrap for tuning + config; it needs no network for those.
    log "applying tuning and config via bootstrap.sh"
    "${STACK_ROOT}/bootstrap.sh" \
        --offline "${BUNDLE}" \
        --skip-ollama --skip-models --skip-opencode --no-verify

    log "verifying"
    "${STACK_ROOT}/verify.sh" || die "verification failed - see output above"

    echo
    ok "offline restore complete"
    dim "start coding: cd your-project && opencode"
}

main "$@"
