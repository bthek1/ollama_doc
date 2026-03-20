set dotenv-load

# Default model
MODEL := "llama3.2"

# Show available commands
default:
    @just --list

# ── Compose service ──────────────────────────────────────────────────────────

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
