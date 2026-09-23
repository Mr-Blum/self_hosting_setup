#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bundle.sh - build a self-contained bundle for airgapped machines.
#
# Run this on a machine WITH internet access (ideally one where the stack is
# already installed, so model blobs can be copied instead of re-downloaded).
# Produces a directory (and optionally a tarball) containing:
#
#   ollama-linux-amd64.tgz     the Ollama runtime
#   opencode-linux-x64.tar.gz  the OpenCode binary
#   models/                    Ollama's content-addressed blob store
#   stack/                     these scripts + config templates
#   MANIFEST.txt               versions + checksums
#
# Transfer the result to the target machine and run restore.sh there.
# ---------------------------------------------------------------------------
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

OUT_DIR="${STACK_ROOT}/bundle"
MAKE_TAR=0
INCLUDE_MODELS=1

usage() {
    cat <<'EOF'
Usage: ./bundle.sh [options]

Options:
  --out DIR       Output directory (default: ./bundle)
  --tar           Also produce DIR.tar for transfer to removable media
  --no-models     Skip model blobs (bundle is then ~150MB instead of ~40GB)
  -h, --help      Show this help

The model blobs are the bulk of the bundle. Copying them beats re-pulling
~37GB per machine, and Ollama's store is content-addressed so it transfers
cleanly as plain files.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)       OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
        --tar)       MAKE_TAR=1; shift ;;
        --no-models) INCLUDE_MODELS=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           err "unknown option: $1"; usage; exit 2 ;;
    esac
done

require_cmd curl tar

mkdir -p "${OUT_DIR}"
log "building bundle in ${OUT_DIR}"

# ---------------------------------------------------------------------------
# 1. Ollama runtime
# ---------------------------------------------------------------------------
fetch_ollama() {
    local dest="${OUT_DIR}/ollama-linux-amd64.tgz"
    if [ -f "${dest}" ]; then
        ok "ollama runtime already bundled ($(human_gb "$(stat -c%s "${dest}")")GB)"
        return 0
    fi
    log "downloading Ollama runtime"
    curl -fL --progress-bar -o "${dest}.part" \
        "https://ollama.com/download/ollama-linux-amd64.tgz"
    mv "${dest}.part" "${dest}"
    ok "ollama runtime ($(human_gb "$(stat -c%s "${dest}")")GB)"
}

# ---------------------------------------------------------------------------
# 2. OpenCode binary
# ---------------------------------------------------------------------------
fetch_opencode() {
    local version="${OPENCODE_VERSION}"

    if [ -z "${version}" ]; then
        log "resolving latest OpenCode release"
        version="$(curl -fsSL "https://api.github.com/repos/${OPENCODE_REPO}/releases/latest" \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "${version}" ] || die "could not resolve latest OpenCode version"
    fi
    ok "OpenCode version ${version}"
    printf '%s\n' "${version}" > "${OUT_DIR}/opencode.version"

    local dest="${OUT_DIR}/${OPENCODE_ASSET}"
    if [ -f "${dest}" ]; then
        ok "opencode already bundled"
        return 0
    fi

    log "downloading ${OPENCODE_ASSET}"
    curl -fL --progress-bar -o "${dest}.part" \
        "https://github.com/${OPENCODE_REPO}/releases/download/${version}/${OPENCODE_ASSET}"
    mv "${dest}.part" "${dest}"
    ok "opencode binary ($(human_gb "$(stat -c%s "${dest}")")GB)"
}

# ---------------------------------------------------------------------------
# 3. Model blobs
#
# Ollama stores models under .../models as:
#   manifests/registry.ollama.ai/library/<name>/<tag>   (small JSON)
#   blobs/sha256-<digest>                               (the weights)
# Copying the whole directory is simplest and safe; the store is
# content-addressed so duplicate layers are already deduplicated.
# ---------------------------------------------------------------------------
copy_models() {
    if [ "${INCLUDE_MODELS}" -eq 0 ]; then
        warn "skipping model blobs (--no-models); the target machine will need to pull them"
        return 0
    fi

    if [ ! -d "${OLLAMA_MODELS_DIR}" ]; then
        warn "no model store at ${OLLAMA_MODELS_DIR}"
        warn "install the stack and pull the models here first, or use --no-models"
        return 0
    fi

    # Verify the models we care about are actually present before copying.
    if have ollama; then
        local m absent=0
        for m in ${STACK_MODELS}; do
            if model_present "${m}"; then
                ok "will bundle ${m}"
            else
                warn "${m} is not present locally and will be missing from the bundle"
                absent=1
            fi
        done
        [ "${absent}" -eq 0 ] || warn "run: ollama pull <model> for anything listed above"
    fi

    log "copying model store (this moves tens of GB)"
    mkdir -p "${OUT_DIR}/models"

    # rsync gives resumability on a large copy; fall back to cp -a.
    if have rsync; then
        as_root rsync -a --info=progress2 \
            "${OLLAMA_MODELS_DIR}/" "${OUT_DIR}/models/"
    else
        as_root cp -a "${OLLAMA_MODELS_DIR}/." "${OUT_DIR}/models/"
    fi

    # The copy runs as root; hand ownership back so the bundle is portable.
    as_root chown -R "$(id -u):$(id -g)" "${OUT_DIR}/models"
    ok "model store bundled ($(du -sh "${OUT_DIR}/models" | cut -f1))"
}

# ---------------------------------------------------------------------------
# 4. The scripts themselves
# ---------------------------------------------------------------------------
copy_stack() {
    log "copying stack scripts"
    mkdir -p "${OUT_DIR}/stack"
    local f
    for f in bootstrap.sh restore.sh verify.sh model.sh bundle.sh README.md; do
        [ -e "${STACK_ROOT}/${f}" ] && cp -p "${STACK_ROOT}/${f}" "${OUT_DIR}/stack/"
    done
    cp -a "${STACK_ROOT}/lib"    "${OUT_DIR}/stack/"
    cp -a "${STACK_ROOT}/config" "${OUT_DIR}/stack/"
    ok "stack scripts bundled"
}

# ---------------------------------------------------------------------------
# 5. Manifest
# ---------------------------------------------------------------------------
write_manifest() {
    local manifest="${OUT_DIR}/MANIFEST.txt"
    log "writing manifest"
    {
        echo "# Local agentic coding stack - offline bundle"
        echo "# built:      $(date -Is)"
        echo "# built on:   $(hostname) / $( (lsb_release -ds 2>/dev/null || echo unknown) )"
        echo
        echo "opencode_version: $(cat "${OUT_DIR}/opencode.version" 2>/dev/null || echo unknown)"
        echo "ollama_version:   $( (ollama --version 2>/dev/null | head -1) || echo unknown)"
        echo "context_length:   ${OLLAMA_CTX}"
        echo "kv_cache_type:    ${OLLAMA_KV_CACHE}"
        echo "models:           ${STACK_MODELS}"
        echo
        echo "## sha256"
        ( cd "${OUT_DIR}" && find . -maxdepth 1 -type f \
            ! -name 'MANIFEST.txt' -exec sha256sum {} \; 2>/dev/null ) || true
        echo
        echo "## model manifests included"
        if [ -d "${OUT_DIR}/models/manifests" ]; then
            ( cd "${OUT_DIR}/models/manifests" && find . -type f | sed 's|^\./||' ) || true
        else
            echo "(none)"
        fi
    } > "${manifest}"
    ok "manifest written"
}

# ---------------------------------------------------------------------------
make_tarball() {
    [ "${MAKE_TAR}" -eq 1 ] || return 0
    local tarball="${OUT_DIR%/}.tar"
    log "creating ${tarball} (not compressed: model blobs are already compressed)"
    tar -cf "${tarball}" -C "$(dirname "${OUT_DIR}")" "$(basename "${OUT_DIR}")"
    ok "tarball: ${tarball} ($(du -sh "${tarball}" | cut -f1))"
}

main() {
    fetch_ollama
    fetch_opencode
    copy_models
    copy_stack
    write_manifest
    make_tarball

    echo
    ok "bundle complete: ${OUT_DIR} ($(du -sh "${OUT_DIR}" | cut -f1))"
    echo
    dim "on the airgapped machine:"
    dim "  1. copy the bundle across"
    dim "  2. cd <bundle>/stack && ./restore.sh --bundle .."
}

main "$@"
