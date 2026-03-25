set dotenv-load

# Default model
MODEL := "qwen2.5:3b"

# Show available commands
default:
    @just --list

# ── Compose service ──────────────────────────────────────────────────────────

# Start the Ollama container stack
[group('Compose Service')]
up:
    @echo "Starting Ollama stack..."
    @docker compose up -d
    @just status

# Stop and remove containers (models are safe — bind mount on host)
[group('Compose Service')]
down:
    @echo "Stopping Ollama stack..."
    @docker compose down

# Restart just the ollama service
[group('Compose Service')]
restart:
    @docker compose restart ollama
    @just status

# Show server status, version, and loaded models
[group('Compose Service')]
status:
    @python3 scripts/status.py

# ── Model management ────────────────────────────────────────────────────────

# Show info about the default model (or pass MODEL=<name>)
[group('Model Management')]
model:
    @echo "Model: {{MODEL}}"
    @docker exec ollama ollama show {{MODEL}}

# List all locally downloaded models
[group('Model Management')]
models:
    @docker exec ollama ollama list

# Pull (download) a model  — usage: just pull MODEL=mistral
[group('Model Management')]
pull model=MODEL:
    @echo "Pulling model: {{model}}"
    @docker exec ollama ollama pull {{model}}

# Remove a model  — usage: just remove MODEL=llama3.2
[group('Model Management')]
remove model=MODEL:
    @echo "Removing model: {{model}}"
    @docker exec ollama ollama rm {{model}}

# Unload a model from GPU memory  — usage: just unload MODEL=llama3.2
[group('Model Management')]
unload model=MODEL:
    @echo "Unloading model from GPU: {{model}}"
    @docker exec ollama ollama stop {{model}}
    @just status

# ── Inference ───────────────────────────────────────────────────────────────

# Run a one-shot prompt  — usage: just run "Tell me a joke"
[group('Inference')]
run prompt="Hello!":
    @docker exec -it ollama ollama run {{MODEL}} "{{prompt}}"

# Start an interactive chat session
[group('Inference')]
chat:
    @docker exec -it ollama ollama run {{MODEL}}

# ── Python / project ────────────────────────────────────────────────────────

# Install Python dependencies with uv
[group('Python / Project')]
install:
    uv sync

# Run main.py
[group('Python / Project')]
demo:
    uv run python main.py

# Build a custom model from the local Modelfile
[group('Python / Project')]
build name="analysis-assistant":
    @echo "Building custom model '{{name}}' from Modelfile..."
    @docker cp Modelfile ollama:/tmp/Modelfile
    @docker exec ollama ollama create {{name}} -f /tmp/Modelfile
    @echo "Done. Run: just run MODEL={{name}}"

# ── Diagnostics ─────────────────────────────────────────────────────────────

# Show GPU info from inside the container
[group('Diagnostics')]
gpu:
    @docker exec ollama nvidia-smi --query-gpu=name,memory.total,memory.free,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null \
        || echo "No NVIDIA GPU detected inside container."

# Tail live logs from the ollama container
[group('Diagnostics')]
logs:
    @docker compose logs -f ollama

# Show disk usage of the models directory (host-side bind mount)
[group('Diagnostics')]
disk:
    @du -sh ~/ollama_doc/models 2>/dev/null || echo "Models directory not found."
