#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify.sh - prove the stack actually works, rather than assuming it does.
#
# Checks, in order of how likely they are to bite you:
#   1. Ollama service is running and reachable
#   2. The tuning env vars actually reached the running process
#   3. Both models are present
#   4. Each model loads 100% onto the GPU at the configured context
#      (a CPU/GPU split means silent ~50x slowdown, not an error)
#   5. Each model emits well-formed tool calls
#   6. OpenCode is installed and its config is valid and points at Ollama
#
# Exit code is non-zero if any check fails, so it is safe to gate on.
# ---------------------------------------------------------------------------
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FAILED=0
QUICK=0
SKIP_LOAD=0

usage() {
    cat <<'EOF'
Usage: ./verify.sh [--quick] [--skip-load]

  --quick      Skip the tool-calling probes (which require loading models).
  --skip-load  Do not load models; only check what is already resident.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --quick)     QUICK=1; shift ;;
        --skip-load) SKIP_LOAD=1; QUICK=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           err "unknown option: $1"; usage; exit 2 ;;
    esac
done

fail() { err "$*"; FAILED=$((FAILED + 1)); }

# ---------------------------------------------------------------------------
check_service() {
    log "[1/6] Ollama service"

    if have systemctl && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
        if systemctl is-active --quiet ollama; then
            ok "ollama.service is active"
        else
            fail "ollama.service is not active (try: sudo systemctl start ollama)"
            return
        fi
    fi

    if curl -fsS --max-time 5 "$(ollama_api)/api/version" >/dev/null 2>&1; then
        ok "API reachable at $(ollama_api)"
    else
        fail "API not reachable at $(ollama_api)"
    fi
}

# ---------------------------------------------------------------------------
# The single most common silent failure: the systemd override was never
# applied, so Ollama is still serving a 4096-token context.
#
# Read the configured environment via `systemctl show`, which is a read-only
# query available to unprivileged users - no sudo prompt. Because that reports
# what systemd is *configured* to pass (not what the running process actually
# got), we additionally prove the service was restarted after the drop-in was
# last written. Together those cover the same ground as reading
# /proc/<pid>/environ, without needing root.
check_tuning() {
    log "[2/6] effective tuning"

    if ! have systemctl; then
        warn "no systemctl; cannot inspect service environment"
        return
    fi

    local env_line
    env_line="$(systemctl show ollama --property=Environment --value 2>/dev/null)"
    if [ -z "${env_line}" ]; then
        warn "systemd reports no Environment for ollama.service; override missing?"
        return
    fi

    # Values here contain no spaces, so whitespace splitting is safe.
    local env_data
    env_data="$(printf '%s\n' "${env_line}" | tr ' ' '\n' | sed 's/^"//; s/"$//')"

    local var expected actual
    for var in OLLAMA_CONTEXT_LENGTH:"${OLLAMA_CTX}" \
               OLLAMA_FLASH_ATTENTION:"${OLLAMA_FLASH_ATTN}" \
               OLLAMA_KV_CACHE_TYPE:"${OLLAMA_KV_CACHE}" \
               OLLAMA_MAX_LOADED_MODELS:"${OLLAMA_MAX_LOADED}" \
               OLLAMA_NUM_PARALLEL:"${OLLAMA_PARALLEL}"; do
        expected="${var#*:}"
        var="${var%%:*}"
        actual="$(printf '%s\n' "${env_data}" | sed -n "s/^${var}=//p" | head -1)"
        if [ "${actual}" = "${expected}" ]; then
            ok "${var}=${actual}"
        elif [ -z "${actual}" ]; then
            fail "${var} is unset in the unit config (expected ${expected}) - override not applied?"
        else
            fail "${var}=${actual} but expected ${expected}"
        fi
    done

    check_config_is_live
}

# Prove the running process actually picked up the current config, rather than
# still running with whatever was in effect before the last edit.
check_config_is_live() {
    if [ "$(systemctl show ollama --property=NeedDaemonReload --value 2>/dev/null)" = "yes" ]; then
        fail "systemd needs a daemon-reload; the unit on disk differs from what is loaded"
        dim  "fix: sudo systemctl daemon-reload && sudo systemctl restart ollama"
        return
    fi

    local dropin="/etc/systemd/system/ollama.service.d/10-local-stack.conf"
    [ -f "${dropin}" ] || { warn "drop-in not found at ${dropin}"; return; }

    local started_raw started_epoch dropin_epoch
    started_raw="$(systemctl show ollama --property=ActiveEnterTimestamp --value 2>/dev/null)"
    [ -n "${started_raw}" ] || return 0

    started_epoch="$(date -d "${started_raw}" +%s 2>/dev/null)" || return 0
    dropin_epoch="$(stat -c %Y "${dropin}" 2>/dev/null)" || return 0

    if [ "${dropin_epoch}" -gt "${started_epoch}" ]; then
        fail "the tuning config was modified after ollama last started - it is NOT in effect"
        dim  "fix: sudo systemctl restart ollama"
    else
        ok "config is live (service started after the last config change)"
    fi
}

# ---------------------------------------------------------------------------
check_models_present() {
    log "[3/6] models present"
    local m
    for m in ${STACK_MODELS}; do
        if model_present "${m}"; then
            ok "${m}"
        else
            fail "${m} is missing (ollama pull ${m})"
        fi
    done
}

# ---------------------------------------------------------------------------
# Loads each model and reports the GPU/CPU split. This is the check that
# answers "does 64k context actually fit in 24GB?"
check_gpu_fit() {
    log "[4/6] VRAM fit at ${OLLAMA_CTX} context"

    if [ "${SKIP_LOAD}" -eq 1 ]; then
        dim "skipped (--skip-load)"
        return
    fi

    local m
    for m in ${STACK_MODELS}; do
        model_present "${m}" || continue

        # Keep only one model resident at a time on a 24GB card.
        local other
        for other in ${STACK_MODELS}; do
            [ "${other}" = "${m}" ] || ollama stop "${other}" >/dev/null 2>&1 || true
        done

        dim "loading ${m} ..."
        # An empty prompt forces a load without generating tokens.
        if ! curl -fsS --max-time 300 "$(ollama_api)/api/generate" \
                -d "$(printf '{"model":"%s","prompt":"","keep_alive":"5m"}' "${m}")" \
                >/dev/null 2>&1; then
            fail "${m} failed to load"
            continue
        fi

        local line processor size
        line="$(ollama ps 2>/dev/null | awk -v m="${m}" '$1==m')"
        if [ -z "${line}" ]; then
            fail "${m} did not appear in 'ollama ps' after loading"
            continue
        fi

        # ollama ps columns: NAME ID SIZE UNIT PROCESSOR... (SIZE has a unit)
        processor="$(printf '%s\n' "${line}" | grep -oE '[0-9]+%/[0-9]+% CPU/GPU|100% GPU|100% CPU' | head -1)"
        size="$(printf '%s\n' "${line}" | awk '{print $3" "$4}')"

        case "${processor}" in
            "100% GPU")
                ok "${m}: ${size}, 100% GPU"
                ;;
            "100% CPU")
                fail "${m}: ${size}, 100% CPU - no GPU offload at all"
                dim "check nvidia-smi and 'journalctl -u ollama -n 50'"
                ;;
            *)
                fail "${m}: ${size}, ${processor} - spilling to system RAM"
                dim "this will be roughly 50x slower. Remedy, in order of preference:"
                dim "  1. OLLAMA_CTX=49152 ./bootstrap.sh --only-tune"
                dim "  2. set OLLAMA_KV_CACHE=q4_0 in config/stack.env"
                dim "  3. make sure nothing else is using the GPU (nvidia-smi)"
                ;;
        esac

        # 'ollama ps' reports the context the model was actually loaded with.
        # This is stronger evidence than checking env vars, because it proves
        # the setting survived all the way to the loaded model.
        # Anchor on the PROCESSOR column (".. GPU" / ".. CPU/GPU") and take the
        # next field: picking "first big integer" would misread an all-digit
        # model ID as the context.
        local served_ctx
        served_ctx="$(printf '%s\n' "${line}" | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^(CPU|GPU|CPU\/GPU|GPU\/CPU)$/ && $(i+1) ~ /^[0-9]+$/) {
                        print $(i+1); exit
                    }
                }
            }')"
        if [ -n "${served_ctx}" ]; then
            if [ "${served_ctx}" = "${OLLAMA_CTX}" ]; then
                ok "${m}: serving ${served_ctx} tokens of context"
            else
                fail "${m}: loaded with ${served_ctx} context, expected ${OLLAMA_CTX}"
                dim "OpenCode is configured for ${OLLAMA_CTX}; a mismatch overflows silently"
            fi
        fi

        if have nvidia-smi; then
            local used total
            used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
            total="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
            dim "GPU memory: ${used} / ${total} MiB ($(awk -v u="${used}" -v t="${total}" \
                'BEGIN{printf "%.0f", u*100/t}')%)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Tool calling is the whole point of an agentic harness. A model that chats
# fine but emits malformed tool calls is useless for OpenCode, so probe it
# directly against the OpenAI-compatible endpoint OpenCode will use.
check_tool_calling() {
    log "[5/6] tool calling"

    if [ "${QUICK}" -eq 1 ]; then
        dim "skipped (--quick)"
        return
    fi

    require_cmd curl
    local have_json=0
    if have jq; then have_json=1; fi

    local m payload response name
    for m in ${STACK_MODELS}; do
        model_present "${m}" || continue

        payload="$(cat <<JSON
{
  "model": "${m}",
  "messages": [
    {"role": "user", "content": "What is the weather in Paris right now? Call the tool."}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": {
          "type": "object",
          "properties": {"city": {"type": "string", "description": "City name"}},
          "required": ["city"]
        }
      }
    }
  ],
  "stream": false
}
JSON
)"

        dim "probing ${m} ..."
        response="$(curl -fsS --max-time 300 \
            -H 'Content-Type: application/json' \
            -d "${payload}" \
            "$(ollama_api)/v1/chat/completions" 2>/dev/null)" || {
            fail "${m}: tool-call request failed"
            continue
        }

        if [ "${have_json}" -eq 1 ]; then
            name="$(printf '%s' "${response}" \
                | jq -r '.choices[0].message.tool_calls[0].function.name // empty' 2>/dev/null)"
            if [ "${name}" = "get_weather" ]; then
                local args
                args="$(printf '%s' "${response}" \
                    | jq -r '.choices[0].message.tool_calls[0].function.arguments // empty')"
                # Arguments arrive as a JSON-encoded string; it must itself parse.
                if printf '%s' "${args}" | jq empty 2>/dev/null; then
                    ok "${m}: well-formed tool call ${name}(${args})"
                else
                    fail "${m}: tool call present but arguments are not valid JSON: ${args}"
                fi
            else
                fail "${m}: no tool_calls in response (model answered in prose instead)"
                dim "raw: $(printf '%s' "${response}" | head -c 300)"
            fi
        else
            if printf '%s' "${response}" | grep -q '"tool_calls"'; then
                ok "${m}: response contains tool_calls (install jq for strict validation)"
            else
                fail "${m}: no tool_calls in response"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
check_opencode() {
    log "[6/6] OpenCode"

    # The installer appends to ~/.bashrc, which the current shell has not
    # re-sourced. A missing PATH entry here is not an install failure, so it
    # must not fail the run - it just needs a new shell.
    local oc_path
    if oc_path="$(find_opencode)"; then
        if have opencode; then
            ok "opencode on PATH ($("${oc_path}" --version 2>/dev/null | head -1)) at ${oc_path}"
        else
            warn "opencode is installed but not on PATH in this shell"
            dim  "installed: ${oc_path} ($("${oc_path}" --version 2>/dev/null | head -1))"
            dim  "the installer added it to ~/.bashrc - open a new terminal, or run:"
            dim  "  source ~/.bashrc"
        fi
    else
        fail "opencode binary not found (looked on PATH, ${OPENCODE_INSTALL_DIR}, ~/.local/bin)"
    fi

    local cfg="${OPENCODE_CONFIG_DIR}/opencode.json"
    if [ ! -f "${cfg}" ]; then
        fail "config missing: ${cfg}"
        return
    fi

    if have jq; then
        if ! jq empty "${cfg}" 2>/dev/null; then
            fail "${cfg} is not valid JSON"
            return
        fi
        ok "config is valid JSON"

        local base
        base="$(jq -r '.provider.ollama.options.baseURL // empty' "${cfg}")"
        if [ "${base}" = "http://${OLLAMA_BIND}/v1" ]; then
            ok "baseURL -> ${base}"
        else
            fail "baseURL is '${base}', expected 'http://${OLLAMA_BIND}/v1'"
        fi

        local m
        for m in ${STACK_MODELS}; do
            if jq -e --arg m "${m}" '.provider.ollama.models[$m]' "${cfg}" >/dev/null 2>&1; then
                local ctx
                ctx="$(jq -r --arg m "${m}" '.provider.ollama.models[$m].limit.context' "${cfg}")"
                if [ "${ctx}" = "${OLLAMA_CTX}" ]; then
                    ok "${m} registered (context ${ctx})"
                else
                    fail "${m} declares context ${ctx} but Ollama serves ${OLLAMA_CTX}"
                    dim "a mismatch here makes OpenCode overflow the window silently"
                fi
            else
                fail "${m} is not registered in ${cfg}"
            fi
        done

        # Offline hygiene: small_model must not point at a hosted provider.
        local small
        small="$(jq -r '.small_model // empty' "${cfg}")"
        case "${small}" in
            ollama/*) ok "small_model is local (${small})" ;;
            "")       warn "small_model unset - OpenCode may default to a hosted model for titles" ;;
            *)        fail "small_model '${small}' is not local; it will try to reach the internet" ;;
        esac
    else
        warn "jq not installed; skipping deep config validation"
    fi
}

# ---------------------------------------------------------------------------
main() {
    echo
    check_service
    echo; check_tuning
    echo; check_models_present
    echo; check_gpu_fit
    echo; check_tool_calling
    echo; check_opencode
    echo

    if [ "${FAILED}" -eq 0 ]; then
        ok "all checks passed"
        exit 0
    fi
    err "${FAILED} check(s) failed"
    exit 1
}

main "$@"
