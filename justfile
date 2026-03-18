set dotenv-load

# Default model and environment
MODEL := "llama3.2"
OLLAMA_HOST := "http://localhost:11434"
OLLAMA_MODELS_DIR := "~/ollama_doc/models"

# Show available commands
default:
    @just --list

# ── Ollama service ──────────────────────────────────────────────────────────

# Start the Ollama server in the background
up:
    @echo "Starting Ollama server..."
    @export OLLAMA_MODELS={{OLLAMA_MODELS_DIR}} && ollama serve &
    @sleep 2
    @just status

# Stop the Ollama server
down:
    @echo "Stopping Ollama server..."
    @pkill -f "ollama serve" && echo "Ollama stopped." || echo "Ollama was not running."

# Restart the Ollama server
restart: down
    @sleep 1
    @just up

# Show server status, version, and loaded models
status:
    @python3 scripts/status.py

# ── Model management ────────────────────────────────────────────────────────

# Show info about the default model (or pass MODEL=<name>)
model:
    @echo "Model: {{MODEL}}"
    @ollama show {{MODEL}}

# List all locally downloaded models
models:
    @ollama list

# Pull (download) a model  — usage: just pull MODEL=mistral
pull model=MODEL:
    @echo "Pulling model: {{model}}"
    @OLLAMA_MODELS={{OLLAMA_MODELS_DIR}} ollama pull {{model}}

# Remove a model  — usage: just remove MODEL=llama3.2
remove model=MODEL:
    @echo "Removing model: {{model}}"
    @ollama rm {{model}}

# ── Inference ───────────────────────────────────────────────────────────────

# Run a one-shot prompt  — usage: just run "Tell me a joke"
run prompt="Hello!":
    @ollama run {{MODEL}} "{{prompt}}"

# Start an interactive chat session
chat:
    @ollama run {{MODEL}}

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
    @OLLAMA_MODELS={{OLLAMA_MODELS_DIR}} ollama create {{name}} -f Modelfile
    @echo "Done. Run: just run MODEL={{name}}"

# ── Diagnostics ─────────────────────────────────────────────────────────────

# Show GPU info (requires nvidia-smi)
gpu:
    @nvidia-smi --query-gpu=name,memory.total,memory.free,utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
        || echo "No NVIDIA GPU detected (or nvidia-smi not installed)."

# Tail the Ollama log (systemd)
logs:
    @journalctl -u ollama -f --no-pager 2>/dev/null || echo "systemd service not found — server output goes to stdout when started with 'just up'."

# Show disk usage of the models directory
disk:
    @du -sh {{OLLAMA_MODELS_DIR}} 2>/dev/null || echo "Models directory not found."
