# Local agentic coding stack

A fully offline Claude-Code-style workflow on one 24GB GPU.

| Layer | Choice | Why |
|---|---|---|
| Agent harness | **OpenCode** (`v1.18.32`) | Model-agnostic from day one; single binary, no runtime deps to vendor |
| Backend | **Ollama** | OpenAI-compatible endpoint, content-addressed model store that copies cleanly between machines |
| Models | **qwen3-coder:30b-a3b-q4_K_M** (default)<br>**muse-glimmer:30b-q4_K_M** | Both fit 24GB individually at q4; switchable with one command |

Target: Ubuntu 22.04, RTX A5000 24GB. No network required after setup.

---

## Quick start

```bash
git clone <this repo> ~/self_hosted && cd ~/self_hosted
./bootstrap.sh          # installs everything, ~37GB of model downloads
opencode                # from inside any project directory
```

`bootstrap.sh` is idempotent — re-run it any time. It calls `sudo` only for
installing Ollama and writing its systemd override; run it as your normal
user, not as root.

| Script | Purpose |
|---|---|
| `bootstrap.sh` | Install / repair / reconfigure the whole stack |
| `verify.sh` | Six health checks; **run this when anything feels wrong** |
| `model.sh` | Preload, switch, and unload models from the shell |
| `bundle.sh` | Build an offline bundle on a connected machine |
| `restore.sh` | Install from that bundle on an airgapped machine |
| `config/stack.env` | Every tunable, one file |

---

## The VRAM problem (read this before changing anything)

Two constraints collide:

- Ollama defaults to a **4096-token** context regardless of what the model
  supports. In an agentic loop that reads files and accumulates tool output,
  this silently truncates and tool calls start failing in ways that look like
  model stupidity rather than misconfiguration.
- OpenCode **requires 64K minimum**.

So we must serve 65,536 tokens of context alongside ~18GB of weights on a
24GB card. The KV cache is what makes this tight.

For Qwen3-Coder-30B-A3B (48 layers, 4 KV heads, head_dim 128), KV cache is
`2 × 48 × 4 × 128 × 2 bytes` = 96 KiB per token:

| KV cache type | KV at 64K | + weights (17.7 GiB) | + compute buffer | Fits in 23.3 GiB usable? |
|---|---|---|---|---|
| `f16` (Ollama default) | 6.0 GiB | 23.7 GiB | ~24.7 GiB | **No** (−1.4 GiB) |
| `q8_0` (our setting) | 3.0 GiB | 20.7 GiB | ~21.7 GiB | **Yes** (+1.6 GiB) |
| `q4_0` | 1.5 GiB | 19.2 GiB | ~20.2 GiB | Yes (+3.1 GiB), but lossier |

Usable = 23.99 GiB card − ~0.65 GiB for the display output. The compute/graph
buffer is an estimate; `verify.sh` measures what actually happens.

That is the whole reason the systemd override sets
`OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`. Flash attention
is not optional here — **KV quantization has no effect without it**.

Muse Glimmer should be more comfortable: its architecture interleaves sliding
window and full attention (3 SWA : 1 full across 52 layers), so only a
quarter of its layers cache the full sequence. I have not independently
confirmed its head configuration, so treat that as expectation rather than
arithmetic — `verify.sh` measures the real placement.

### If a model does not fit

`verify.sh` reports a CPU/GPU split instead of `100% GPU`. That is a ~50x
slowdown, not an error, so nothing will tell you unless you look. Remedies in
order of preference:

```bash
# 1. Lower the context (still above OpenCode's 64K floor? see note)
OLLAMA_CTX=49152 ./bootstrap.sh --only-tune

# 2. More aggressive KV quantization - edit config/stack.env
OLLAMA_KV_CACHE=q4_0   # then: ./bootstrap.sh --only-tune

# 3. Make sure nothing else is on the GPU
nvidia-smi
```

Dropping below 64K contradicts OpenCode's stated requirement; it will still
run but expect degraded long-task behaviour. Prefer freeing the GPU first.

> If you change `OLLAMA_CTX`, re-run `./bootstrap.sh --only-tune --only-config`
> so the systemd override **and** `opencode.json`'s `limit.context` stay in
> sync. A mismatch makes OpenCode overflow the window silently.

---

## Switching models

Only one model fits in VRAM at a time. Loading one evicts the other.

**Inside OpenCode** — the normal path:

```
/models
```

**From the shell** — useful to preload before you start so your first prompt
isn't stuck behind a 10–30s load:

```bash
./model.sh list          # what's on disk, what's resident
./model.sh secondary     # preload Muse Glimmer (evicts the other)
./model.sh primary       # preload Qwen3-Coder
./model.sh free          # unload everything, free the GPU
./model.sh status        # ollama ps + live GPU memory
```

Which to use: Qwen3-Coder is the default and the stronger pure-coding
generalist with a 256K native window. Muse Glimmer is multimodal (it accepts
images/screenshots) and tuned for long-horizon tool use and failure recovery.
Neither claim is independently benchmarked here — try both on your own
repository, which is worth more than any leaderboard.

---

## Offline / airgapped machines

Model weights are the expensive part, and Ollama's store is content-addressed
plain files, so you copy them rather than re-download ~37GB per machine.

**On a connected machine** (ideally one where the stack already works):

```bash
./bundle.sh --tar        # ~40GB with models, ~150MB with --no-models
```

Produces `bundle/` containing the Ollama runtime, the OpenCode binary, the
model blob store, these scripts, and a `MANIFEST.txt` with sha256 sums.

**On the airgapped machine:**

```bash
cd <bundle>/stack
./restore.sh --bundle ..
```

`restore.sh` verifies checksums first, then makes zero network calls. It also
handles the step people most often miss: `chown`-ing the model store to the
`ollama` user, without which Ollama silently cannot see the weights.

Pin versions for byte-identical installs across a fleet:

```bash
OPENCODE_VERSION=v1.18.32 ./bundle.sh
```

### What we did to keep it actually offline

- `enabled_providers: ["ollama"]` — no other provider loads, even if stray
  API keys exist in the environment.
- `small_model` points at the **local** model. By default OpenCode uses a
  Zen-hosted `gpt-5-nano` for session-title generation, which would phone
  home on every conversation.
- `share: "disabled"` and `autoupdate: false`.
- `OLLAMA_NO_CLOUD=1` disables Ollama's cloud models and web search.

---

## Security note

Ollama binds `127.0.0.1:11434` and has **no authentication**. Anything that
can reach that port can use your GPU and read any prompt. If you change
`OLLAMA_BIND` to expose it on a network interface, put an authenticating
reverse proxy in front of it first.

OpenCode by default permits file edits and shell commands without asking. To
require approval, add to `~/.config/opencode/opencode.json`:

```json
{ "permission": { "edit": "ask", "bash": "ask" } }
```

---

## Troubleshooting

Run `./verify.sh` first — it checks the six things that break, in the order
they break.

| Symptom | Likely cause |
|---|---|
| Tool calls fail / agent loses track mid-task | Context too small. `verify.sh` check 2 confirms whether the override actually reached the running process. |
| Everything is glacially slow | Model spilled to system RAM. `verify.sh` check 4, then the ladder above. |
| `opencode` not found | `~/.opencode/bin` not on `PATH`. The installer appends it to `~/.bashrc`, so open a new terminal or `source ~/.bashrc`. |
| Models missing after a restore | Ownership. `sudo chown -R ollama:ollama /usr/share/ollama` |
| Config edits have no effect | Project-level `opencode.json` overrides the global one. |

Useful raw commands:

```bash
systemctl status ollama
journalctl -u ollama -n 50 --no-pager
ollama ps                       # PROCESSOR column must read 100% GPU
systemctl cat ollama            # confirm the override is present
```

---

## Layout

```
self_hosted/
├── bootstrap.sh                     # installer (online + offline paths)
├── verify.sh                        # health checks
├── model.sh                         # load/switch/unload
├── bundle.sh / restore.sh           # airgap transfer
├── lib/common.sh                    # shared helpers
└── config/
    ├── stack.env                    # all tunables (single source of truth)
    ├── opencode.json.tmpl           # rendered to ~/.config/opencode/
    └── ollama-override.conf.tmpl    # rendered to systemd drop-in
```

Configs are generated from templates so `stack.env` stays the only place a
value is defined. Edit the templates or `stack.env`, never the rendered output.
