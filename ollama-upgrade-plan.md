# Ollama Production Upgrade Plan

## Overview

This plan covers upgrading the existing bare-metal Ollama setup (v0.18.1) to a
production-grade Docker Compose deployment. It introduces container isolation,
model pre-loading, resource control, and an optional Nginx reverse proxy.

**Last updated:** 2026-03-20

**Current state (from Phase 1–5 setup):**
- ~~Ollama v0.18.1 running via `ollama serve` (bare-metal, CPU-only)~~ → service stopped & disabled
- Models stored in `~/ollama_doc/models/`
- `llm` CLI and Python `ollama` package working

**Environment confirmed:**
- Docker Engine 28.5.1 + Compose v5.1.0
- NVIDIA GeForce GTX 1660 (6 GB VRAM), driver 580.105.08, CUDA 13.0
- NVIDIA Container Toolkit 1.19.0, CDI configured (`nvidia.com/gpu=all`)

**Target state:**
- Ollama `latest` in Docker Compose
- Models persisted in `~/ollama_doc/models/` (bind mount — same location as bare-metal)
- Model pre-loading via an init container
- Healthcheck-gated startup

**Resolved (2026-03-20):** Three issues were fixed to get the stack running:
1. **GPU passthrough** — replaced `runtime: nvidia` + env vars with Docker's native CDI string syntax (`devices: ["nvidia.com/gpu=all"]`). The `deploy.resources` approach also fails with cgroup v2 BPF; CDI is the correct path.
2. **Volume mount path** — corrected bind mount to `/root/.ollama/models` (not `/root/.ollama`), matching Ollama's `OLLAMA_MODELS` default.
3. **Healthcheck** — replaced `curl` (not in the Ollama image) with `ollama list`.

---

## Phase Overview

| Phase | Name                          | Goal                                                 |
|-------|-------------------------------|------------------------------------------------------|
| 6     | Docker prerequisites          | Install Docker Engine + Compose plugin               |
| 7     | Compose service definition    | Write `docker-compose.yml` with Ollama + init svc    |
| 8     | Model migration               | Verify existing models are visible via bind mount    |
| 9     | Python & `llm` CLI re-wiring  | Point existing tooling at the containerised server   |
| 10    | Justfile update               | Swap bare-metal recipes for Docker Compose commands  |

---

## Phase 6 — Docker Prerequisites

### 6.1 Install Docker Engine

```bash
# Install only if Docker is not already present
if ! command -v docker &>/dev/null; then
  # Remove any conflicting legacy packages
  sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  # Install using the convenience script (or follow the manual apt method)
  curl -fsSL https://get.docker.com | sh

  # Add your user to the docker group (avoids sudo on every docker command)
  sudo usermod -aG docker $USER
  newgrp docker
else
  echo "Docker already installed: $(docker --version)"
fi
```

Verify:

```bash
docker --version          # Docker Engine 26+
docker compose version    # Docker Compose v2.x
```

### 6.2 (GPU) Install NVIDIA Container Toolkit

Skip this section if running CPU-only.

```bash
# Install only if the toolkit is not already present
if ! dpkg -s nvidia-container-toolkit &>/dev/null; then
  distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
  curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
  sudo systemctl restart docker
else
  echo "NVIDIA Container Toolkit already installed"
fi

# Verify GPU passthrough
docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi
```

> **CPU-only note:** If no GPU is available, remove the `deploy.resources` block
> from the Compose file in Phase 7.

### 6.3 Stop and Disable the Bare-Metal Service

```bash
# Stop ollama serve if it is running as a systemd service
sudo systemctl stop ollama
sudo systemctl disable ollama

# Confirm port 11434 is now free
ss -tlnp | grep 11434
```

**Phase 6 Checklist** ✅ Complete
- [x] Docker Engine installed — v28.5.1, `docker compose version` v5.1.0
- [x] User added to `docker` group
- [x] NVIDIA Container Toolkit installed — v1.19.0, CDI spec entries confirmed
- [x] Bare-metal `ollama` service stopped and disabled
- [x] `/usr/local/bin/ollama` and `~/bin/ollama` binaries removed
- [x] `ollama.service` unit file removed, `daemon-reload` run
- [x] `ollama` system user/group removed (`userdel`/`groupdel`)
- [x] `~/.ollama/` config dir retained (contains identity keys — remove manually if not needed)

---

## Phase 7 — Compose Service Definition

### 7.1 Create the Project Layout

```
~/ollama_doc/
├── docker-compose.yml      ← new
├── .env                    ← new (secrets/tunables, never committed)
├── Modelfile
├── main.py
└── pyproject.toml
```

### 7.2 Write `docker-compose.yml`

```bash
cat > ~/ollama_doc/docker-compose.yml <<'EOF'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "127.0.0.1:11434:11434"         # loopback only — never 0.0.0.0 in prod
    volumes:
      - ~/ollama_doc/models:/root/.ollama  # bind mount — models stored on host at ~/ollama_doc/models/
    environment:
      OLLAMA_NUM_PARALLEL: "4"          # concurrent request slots
      OLLAMA_MAX_LOADED_MODELS: "2"     # models resident in VRAM/RAM
      OLLAMA_FLASH_ATTENTION: "1"
      OLLAMA_KEEP_ALIVE: "10m"          # evict from memory after 10 min idle
      OLLAMA_ORIGINS: "http://localhost:8000"  # lock down CORS
    # Remove the deploy block entirely if running CPU-only
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s

  ollama-init:
    image: ollama/ollama:latest
    container_name: ollama-init
    depends_on:
      ollama:
        condition: service_healthy      # waits for healthcheck to pass
    environment:
      OLLAMA_HOST: "http://ollama:11434"
    entrypoint: >
      sh -c "
        ollama pull llama3.2 &&
        ollama pull bge-large-en-v1.5
      "
    restart: "no"                       # runs once, exits cleanly
EOF
```

> **What `ollama-init` does:** pulls your models once after the server is healthy.
> No cold-load latency on the first real inference request.

> **⚠ CDI devices syntax note (Compose v5):** The `devices` block using
> `driver: cdi` + `device_ids` is rejected by Compose v5 with
> *"missing a mount target"*. Replace it with the `deploy.resources` GPU
> reservation block shown in the original template (Phase 7.2 above).
> The `docker-compose.yml` in this repo needs this fix before `up` will succeed.

### 7.3 Start the Stack

```bash
cd ~/ollama_doc
docker compose up -d

# Watch startup logs
docker compose logs -f

# Confirm the health status
docker compose ps
```

Expected output once healthy:

```
NAME          STATUS                   PORTS
ollama        Up 2 minutes (healthy)   127.0.0.1:11434->11434/tcp
ollama-init   Exited (0)
```

**Phase 7 Checklist** ✅ Complete
- [x] `docker-compose.yml` created in `~/ollama_doc/`
- [x] `justfile` updated with Docker Compose recipes
- [x] GPU passthrough fixed — using native CDI `devices: ["nvidia.com/gpu=all"]`
- [x] Healthcheck fixed — using `ollama list` (no `curl` in image)
- [x] Volume mount fixed — bind to `/root/.ollama/models`
- [x] `docker compose up -d` succeeds
- [x] `ollama` service reaches `healthy` state
- [x] `ollama-init` exits with code `0`
- [x] `curl http://localhost:11434/api/tags` returns model list

---

## Phase 8 — Model Migration

The bare-metal models live in `~/ollama_doc/models/`. Because the container is
bind-mounted to the same directory, **no data movement is needed** — the
container reads the existing blobs directly. `ollama-init` will pull any missing
models on first run.

### 8.1 Ensure the Models Directory Exists

```bash
mkdir -p ~/ollama_doc/models
```

Existing blobs already in `~/ollama_doc/models/` are immediately visible to the
container — no copy or re-download required.

### 8.2 List Models

```bash
# via the API
curl -s http://localhost:11434/api/tags | python3 -m json.tool

# or exec into the container
docker exec ollama ollama list
```

**Phase 8 Checklist** ✅ Complete
- [x] `~/ollama_doc/models/` exists and contains existing blobs (9 blob files present)
- [x] Models visible in `curl http://localhost:11434/api/tags` — `llama3.2:latest`, `my-coder:latest`
- [x] `llama3.2` and custom `my-coder` model are present
- [x] No errors in `docker compose logs ollama`

---

## Phase 9 — Python & `llm` CLI Re-Wiring

The server is now at the same address (`http://localhost:11434`), so existing
Python scripts and `llm` CLI commands require no changes — as long as the
container port binding stays `127.0.0.1:11434:11434`.

### 9.1 Verify Python Integration

```bash
source ~/ollama_doc/.venv/bin/activate

python - <<'EOF'
import ollama
r = ollama.chat(model="llama3.2", messages=[{"role":"user","content":"ping"}])
print(r["message"]["content"])
EOF
```

### 9.2 Verify `llm` CLI

```bash
source ~/ollama_doc/.venv/bin/activate
llm -m llama3.2 "ping"
```

### 9.3 Update `main.py` (if it hard-codes the host)

If `main.py` or any script sets `OLLAMA_HOST` to a bare-metal path, update it:

```python
# Before (bare-metal explicit host, if set)
# client = ollama.Client(host="http://localhost:11434")

# After — same URL, works for both bare-metal and Docker with loopback binding
client = ollama.Client(host="http://localhost:11434")
```

No URL change is needed because the port binding is identical.

**Phase 9 Checklist** ✅ Complete
- [x] `ollama.chat()` Python call returns a response
- [x] `llm -m llama3.2` returns a response
- [x] No changes needed to `main.py` — same `http://localhost:11434` address

---

## Phase 10 — Justfile Update

The existing `justfile` drives the server via `ollama serve` and `pkill`. After
moving to Docker Compose, those recipes need to delegate to `docker compose` and
`docker exec` instead.

### 10.1 Replace `justfile`

```bash
cat > ~/ollama_doc/justfile <<'EOF'
set dotenv-load

# Default model
MODEL := "llama3.2"

# Show available commands
default:
    @just --list

# ── Compose service ─────────────────────────────────────────────────────────

# Start the Ollama container stack
up:
    @echo "Starting Ollama stack..."
    @docker compose up -d
    @just status

# Stop and remove containers (models are safe — bind mount on host)
down:
    @echo "Stopping Ollama stack..."
    @docker compose down

# Restart just the ollama service
restart:
    @docker compose restart ollama
    @just status

# Show server status, version, and loaded models
status:
    @python3 scripts/status.py

# ── Model management ────────────────────────────────────────────────────────

# Show info about the default model (or pass MODEL=<name>)
model:
    @echo "Model: {{MODEL}}"
    @docker exec ollama ollama show {{MODEL}}

# List all locally downloaded models
models:
    @docker exec ollama ollama list

# Pull (download) a model  — usage: just pull MODEL=mistral
pull model=MODEL:
    @echo "Pulling model: {{model}}"
    @docker exec ollama ollama pull {{model}}

# Remove a model  — usage: just remove MODEL=llama3.2
remove model=MODEL:
    @echo "Removing model: {{model}}"
    @docker exec ollama ollama rm {{model}}

# ── Inference ───────────────────────────────────────────────────────────────

# Run a one-shot prompt  — usage: just run "Tell me a joke"
run prompt="Hello!":
    @docker exec -it ollama ollama run {{MODEL}} "{{prompt}}"

# Start an interactive chat session
chat:
    @docker exec -it ollama ollama run {{MODEL}}

# ── Python / project ────────────────────────────────────────────────────────

# Install Python dependencies with uv
install:
    uv sync

# Run main.py
demo:
    uv run python main.py

# Build a custom model from the local Modelfile
build name="coding-assistant":
    @echo "Building custom model '{{name}}' from Modelfile..."
    @docker cp Modelfile ollama:/tmp/Modelfile
    @docker exec ollama ollama create {{name}} -f /tmp/Modelfile
    @echo "Done. Run: just run MODEL={{name}}"

# ── Diagnostics ─────────────────────────────────────────────────────────────

# Show GPU info from inside the container
gpu:
    @docker exec ollama nvidia-smi --query-gpu=name,memory.total,memory.free,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null \
        || echo "No NVIDIA GPU detected inside container."

# Tail live logs from the ollama container
logs:
    @docker compose logs -f ollama

# Show disk usage of the models directory (host-side bind mount)
disk:
    @du -sh ~/ollama_doc/models 2>/dev/null || echo "Models directory not found."
EOF
```

### 10.2 Verify Recipes

```bash
just up        # starts docker compose stack
just models    # lists models via docker exec
just status    # hits http://localhost:11434 — same as before
just logs      # tails docker compose logs
```

**Phase 10 Checklist** ✅ Complete
- [x] `justfile` updated in `~/ollama_doc/`
- [x] `just up` starts the Compose stack
- [x] `just models` lists models via `docker exec`
- [x] `just status` shows Ollama v0.18.2 + loaded model
- [x] `just gpu` shows GTX 1660 SUPER (6 GB) inside container
- [x] `just logs` tails container logs

---

| Variable                   | What it does                      | Recommended value               |
|----------------------------|-----------------------------------|---------------------------------|
| `OLLAMA_NUM_PARALLEL`      | Concurrent request slots          | `2`–`4` depending on VRAM/RAM   |
| `OLLAMA_MAX_LOADED_MODELS` | Models kept in VRAM/RAM           | `1`–`2`                         |
| `OLLAMA_FLASH_ATTENTION`   | Flash attention kernel            | `1` always                      |
| `OLLAMA_KEEP_ALIVE`        | Memory eviction timeout           | `10m` for RAG workloads         |
| `OLLAMA_ORIGINS`           | CORS allowed origins              | Lock to your client origin      |
| `OLLAMA_HOST`              | Bind address (inside container)   | `0.0.0.0:11434`                 |

---

## Known Gotchas

| Gotcha | Detail |
|--------|--------|
| `OLLAMA_KEEP_ALIVE=0` | Unloads the model after every request — causes constant cold-load latency in RAG pipelines. Use `5m` minimum. |
| `latest` image tag | This setup uses `ollama/ollama:latest`. Run `docker compose pull && docker compose up -d` to upgrade. Be aware that `latest` may introduce breaking changes — test in a non-production environment before pulling on a live server. |
| Port binding `0.0.0.0` | Binding to `0.0.0.0:11434` exposes Ollama to the entire network without auth. Keep `127.0.0.1:11434:11434` in prod. |
| GPU `deploy` block on CPU host | Compose will error if the `deploy.resources` block references `nvidia` on a machine with no GPU driver. Remove or comment out that block for CPU-only. |
| CDI `devices` syntax in Compose v5 | Using `devices: [{driver: cdi, device_ids: [...]}]` fails with *"missing a mount target"* in Compose v5. Use the `deploy.resources.reservations.devices` block with `driver: nvidia` instead — it works with both the legacy nvidia runtime and CDI. |
| Model cold-load on restart | Without `ollama-init`, the first request after a restart triggers a model load (seconds to minutes). The init container eliminates this. |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ollama-init` exits with non-zero code | Check `docker compose logs ollama-init` — usually a DNS issue or the healthcheck hasn't passed yet. |
| `connection refused` on port 11434 | Run `docker compose ps` — confirm `ollama` is `healthy`, not just `running`. |
| Models not found after migration | Run `docker exec ollama ollama list` — if empty, re-run `docker compose run --rm ollama-init`. |
| GPU not detected inside container | Confirm `nvidia-container-toolkit` is installed and `docker run --gpus all nvidia/cuda ... nvidia-smi` works. |

---

## Master Upgrade Checklist

- [x] **Phase 6** — Docker 28.5.1 + Compose v5.1.0 + NVIDIA toolkit 1.19.0 installed; bare-metal service disabled
- [x] **Phase 7** — CDI + healthcheck + volume mount fixed; stack running healthy
- [x] **Phase 8** — `llama3.2:latest` and `my-coder:latest` visible at `/api/tags`
- [x] **Phase 9** — Python `ollama.chat()` and `llm` CLI both return responses
- [x] **Phase 10** — All justfile recipes verified: `up`, `models`, `status`, `gpu`, `logs`

**Upgrade complete as of 2026-03-20.**

---

## Upgrade Summary

| Item                  | Before (bare-metal)               | After (Docker Compose)                     |
|-----------------------|-----------------------------------|--------------------------------------------|
| Ollama version        | 0.18.1                            | latest                                     |
| Process management    | `systemd` / manual `ollama serve` | Docker Compose `restart: unless-stopped`   |
| Model storage         | `~/ollama_doc/models/`            | `~/ollama_doc/models/` (bind mount, unchanged) |
| Model pre-loading     | Manual `ollama pull`              | `ollama-init` init container               |
| Port exposure         | `0.0.0.0:11434` (bare-metal)      | `127.0.0.1:11434:11434` (loopback only)    |
| GPU support           | CPU-only                          | NVIDIA passthrough via Container Toolkit   |
| Justfile recipes      | `ollama serve` / `pkill`          | `docker compose up/down`, `docker exec`    |
