# Ollama + LLM Setup Plan

## Overview

This plan covers installing Ollama, pulling models, and integrating with the `llm` CLI tool for local LLM inference. It is organized into five phases — from bare-metal installation through to advanced customization.

---

## Phase Overview

| Phase | Name                        | Goal                                        |
|-------|-----------------------------|---------------------------------------------|
| 1     | Prerequisites & Installation | Get Ollama installed and running            |
| 2     | First Model & Basic Usage    | Pull a model and run your first prompt      |
| 3     | `llm` CLI Integration        | Control Ollama via the `llm` CLI tool       |
| 4     | Python & API Integration     | Use Ollama programmatically                 |
| 5     | Advanced Configuration       | Production setup, custom models, hardening  |

---

## Phase 1 — Prerequisites & Installation

### 1.1 Prerequisites

- Linux / macOS / Windows (WSL2)
- `curl` installed
- Python 3.8+ (for `llm` CLI)
- GPU optional but recommended (NVIDIA with CUDA, or Apple Silicon)

### 1.2 Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### 1.3 Configure Model Storage Directory

Store all Ollama models and data inside the project folder:

```bash
# Create the models directory
mkdir -p ~/ollama_doc/models

# Set the environment variable for the current session
export OLLAMA_MODELS=~/ollama_doc/models

# Persist it in your shell profile
echo 'export OLLAMA_MODELS=~/ollama_doc/models' >> ~/.bashrc
source ~/.bashrc
```

> All models pulled via `ollama pull` will now be saved to `~/ollama_doc/models`.

### 1.4 Verify Installation

```bash
ollama --version
```

### 1.5 Start the Ollama Server

```bash
ollama serve
```

> By default, Ollama listens on `http://localhost:11434`.

### 1.6 (Linux) Run as a systemd Service

To persist `OLLAMA_MODELS` when running as a service, add an override:

```bash
sudo systemctl edit ollama
```

Add the following and save:

```ini
[Service]
Environment="OLLAMA_MODELS=/home/bthek1/ollama_doc/models"
```

Then enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl start ollama
sudo systemctl status ollama
```

**Phase 1 Checklist**
- [x] Install Ollama (v0.18.1 already installed)
- [x] Create `~/ollama_doc/models` directory
- [x] Set `OLLAMA_MODELS=~/ollama_doc/models` in shell profile
- [x] Verify `ollama --version` works
- [x] Confirm server starts and listens on port `11434`

> **Note:** Systemd override requires your sudo password. Run manually:
> ```bash
> sudo mkdir -p /etc/systemd/system/ollama.service.d
> sudo tee /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
> [Service]
> Environment="OLLAMA_MODELS=/home/bthek1/ollama_doc/models"
> EOF
> sudo systemctl daemon-reload && sudo systemctl enable --now ollama
> ```

---

## Phase 2 — First Model & Basic Usage

### 2.1 Pull a Model

```bash
# Pull a small, fast model
ollama pull llama3.2

# Pull a larger, more capable model
ollama pull mistral

# Pull a code-focused model
ollama pull codellama

# List all downloaded models
ollama list
```

### 2.2 Recommended Models by Use Case

| Use Case         | Model              | Size   |
|------------------|--------------------|--------|
| General chat     | `llama3.2`         | ~2 GB  |
| General chat     | `mistral`          | ~4 GB  |
| Code generation  | `codellama`        | ~4 GB  |
| Small / fast     | `phi3`             | ~2 GB  |
| Long context     | `llama3.1:70b`     | ~40 GB |

### 2.3 Test Ollama Directly

```bash
# Quick one-shot prompt
ollama run llama3.2 "Explain transformers in 2 sentences"

# Interactive chat session
ollama run mistral
```

**Phase 2 Checklist**
- [x] Pull at least one model (`ollama pull llama3.2`)
- [x] Run a one-shot prompt successfully
- [ ] Start an interactive chat session (run `ollama run mistral` or `ollama run llama3.2` manually)

---

## Phase 3 — `llm` CLI Integration

### 3.1 Install the `llm` CLI Tool

```bash
uv add llm
```

```bash
llm --version
```

### 3.2 Install the Ollama Plugin

```bash
uv add llm-ollama
```

### 3.3 Verify Models Are Visible

```bash
llm models list
```

> Make sure `ollama serve` is running before listing models.

### 3.4 Run Prompts via `llm`

```bash
# One-shot prompt
llm -m ollama/llama3.2 "What is the capital of France?"

# Set a default model (skips -m flag)
llm models default ollama/llama3.2
llm "Summarize the Rust ownership model"

# Multi-turn conversation
llm chat -m ollama/mistral
```

**Phase 3 Checklist**
- [x] Install `llm` (v0.29) and `llm-ollama` (v0.15.1) — venv at `~/ollama_doc/.venv/` (managed by `uv`)
- [x] Run a prompt via `llm -m llama3.2` (alias — the plugin uses model alias, not `ollama/` prefix)
- [x] Set a default model (`llama3.2`)
- [ ] Try a multi-turn chat session (run `~/ollama_doc/.venv/bin/llm chat -m llama3.2` manually)

> **Note:** Use `~/ollama_doc/.venv/bin/llm` (or activate the venv: `source ~/ollama_doc/.venv/bin/activate`)

---

## Phase 4 — Python & API Integration

### 4.1 Python — `ollama` Package

```bash
uv add ollama
```

```python
import ollama

response = ollama.chat(
    model="llama3.2",
    messages=[{"role": "user", "content": "Why is the sky blue?"}]
)
print(response["message"]["content"])
```

### 4.2 Python — `llm` Library

```python
import llm

model = llm.get_model("ollama/llama3.2")
response = model.prompt("Explain recursion simply")
print(response.text())
```

### 4.3 REST API (Direct HTTP)

Ollama exposes an OpenAI-compatible API.

```bash
# Generate endpoint
curl http://localhost:11434/api/generate \
  -d '{
    "model": "llama3.2",
    "prompt": "Tell me a joke",
    "stream": false
  }'

# Chat endpoint
curl http://localhost:11434/api/chat \
  -d '{
    "model": "llama3.2",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": false
  }'
```

**Phase 4 Checklist**
- [x] Install `ollama` Python package (v0.6.1) in `~/ollama_doc/.venv/` (managed by `uv`)
- [x] Run a Python script using `ollama.chat()`
- [x] Successfully call the REST API with `curl`

---

## Phase 5 — Advanced Configuration

### 5.1 Environment Variables

| Variable                   | Purpose                                       |
|----------------------------|-----------------------------------------------|
| `OLLAMA_HOST`              | Bind address (default: `127.0.0.1:11434`)     |
| `OLLAMA_MODELS`            | Custom model storage path                     |
| `OLLAMA_NUM_PARALLEL`      | Parallel request limit                        |
| `OLLAMA_MAX_LOADED_MODELS` | Max models held in memory                     |

```bash
# This project uses ~/ollama_doc/models for all model storage
export OLLAMA_MODELS=~/ollama_doc/models

# Verify models are stored in the right place
ls ~/ollama_doc/models

# Expose Ollama on the local network (with custom model path)
OLLAMA_HOST=0.0.0.0 OLLAMA_MODELS=~/ollama_doc/models ollama serve
```

### 5.2 Custom Models with Modelfile

Store your `Modelfile` in the project folder for easy access:

```bash
# Create Modelfile in the project directory
cat > ~/ollama_doc/Modelfile <<'EOF'
FROM llama3.2

SYSTEM "You are a helpful coding assistant. Answer concisely."

PARAMETER temperature 0.7
PARAMETER num_ctx 4096
EOF
```

Build and run:

```bash
ollama create my-coder -f ~/ollama_doc/Modelfile
ollama run my-coder
```

### 5.3 Troubleshooting

| Problem                        | Fix                                                        |
|--------------------------------|------------------------------------------------------------|
| `connection refused`           | Run `ollama serve` first                                   |
| Model not found                | Run `ollama pull <model>`                                  |
| GPU not detected               | Install NVIDIA drivers + CUDA toolkit                      |
| `llm-ollama` models not listed | Ensure Ollama server is running before `llm models list`   |
| Slow inference                 | Use a smaller model or enable GPU offloading               |

**Phase 5 Checklist**
- [x] Configure environment variables (`OLLAMA_MODELS` in `~/.bashrc`)
- [ ] (Optional) Expose server on local network
- [x] Create and run a custom Modelfile (`~/ollama_doc/Modelfile` → model `my-coder`)
- [ ] Validate GPU is detected if available (no GPU found — CPU inference running)

---

## Master Checklist

- [x] **Phase 1** — Ollama installed and server running
- [x] **Phase 2** — Model pulled and first prompt working
- [x] **Phase 3** — `llm` CLI with Ollama plugin working
- [x] **Phase 4** — Python and REST API calls working
- [x] **Phase 5** — Production config and custom models set up

---

## Setup Summary (Completed March 18, 2026)

| Item | Details |
|------|---------|
| Ollama version | 0.18.1 |
| Model storage | `~/ollama_doc/models/` |
| Models downloaded | `llama3.2:latest`, `my-coder` (custom) |
| Python venv | `~/ollama_doc/.venv/` (Python 3.12, managed by `uv`) |
| pyproject.toml | `~/ollama_doc/pyproject.toml` (dependencies tracked by `uv`) |
| Packages installed | `llm` 0.29, `llm-ollama` 0.15.1, `ollama` 0.6.1 |
| llm default model | `llama3.2` |
| Server | `ollama serve` (CPU-only, 12 GiB RAM) |
| SSH key fix | Generated new `~/.ollama/id_ed25519` key (was empty) |

---

## References

- Ollama docs: https://ollama.com/docs
- llm CLI docs: https://llm.datasette.io
- llm-ollama plugin: https://github.com/taketwo/llm-ollama
- Ollama model library: https://ollama.com/library
