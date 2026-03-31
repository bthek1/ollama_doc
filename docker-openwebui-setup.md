# Docker Open WebUI Setup Plan

## Overview

This plan covers adding **Open WebUI** to your existing Ollama Docker setup. Open WebUI is a user-friendly web interface for interacting with Ollama models, providing a ChatGPT-like experience for local LLM inference.

### Current Setup
- **Ollama Service**: Accessible on port 11434 from any IP address
- **Open WebUI**: Accessible on port 3000 from any IP address
- **Models**: Stored in bind mount (`./models`)
- **Networking**: Docker network with GPU passthrough
- **Architecture**: Docker Compose with ollama + ollama-init + open-webui services

**⚠️ Security Note**: Both services are accessible from any IP on your network (and internet if ports are forwarded). See [Phase 5.2](#52-security-considerations) for firewall and authentication recommendations.

---

## What is Open WebUI?

Open WebUI is a self-hosted web application that provides:
- **Web Chat Interface**: ChatGPT-like UI for model interactions
- **Model Management**: Switch between available models
- **Conversation History**: Persistent chat sessions
- **Document Upload**: Context feeding for RAG workflows
- **Admin Panel**: User/model management
- **API Compatibility**: OpenAI-compatible API endpoint

---

## Prerequisites

✅ Already Met:
- Docker & Docker Compose installed
- Ollama service running (accessible on port 11434)
- Models available in `./models` directory
- Linux host with Docker

New Requirements:
- Additional port for WebUI (recommend 3000 or 8080)
- Sufficient disk space for WebUI database (~500MB)
- Browser for accessing the web interface

---

## Architecture

```
┌─────────────────────────────────────────┐
│        Docker Host (Linux)              │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐   │
│  │    Docker Network (User)        │   │
│  │                                 │   │
│  │  ┌──────────────┐               │   │
│  │  │   Ollama     │               │   │
│  │  │  :11434      │◄──────────┐   │   │
│  │  │  (GPU)       │           │   │   │
│  │  └──────────────┘           │   │   │
│  │                             │   │   │
│  │  ┌──────────────┐           │   │   │
│  │  │  Open WebUI  │           │   │   │
│  │  │    :3000     │───────────┘   │   │
│  │  │              │               │   │
│  │  └──────────────┘               │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │      Host Volumes               │   │
│  │  - /ollama_doc/models (RO)      │   │
│  │  - openwebui_data (Docker vol)  │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

---

## Phase 1: Update docker-compose.yml

### 1.1 Create Docker Network (Optional but Recommended)

Add a custom network to facilitate communication:

```yaml
networks:
  ollama-network:
    driver: bridge
```

### 1.2 Add Open WebUI Service

Add this service to your `docker-compose.yml`:

```yaml
  open-webui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "0.0.0.0:3000:8080"                # accessible from any IP address
    environment:
      OLLAMA_API_BASE_URL: "http://ollama:11434"
      OLLAMA_SHOW_ADMIN_DETAILS: "True"
      SCOPED_MODEL_PERMISSIONS: "True"
      WEBUI_SECRET_KEY: "your-secret-key-change-this"
      # Optional: Set admin credentials
      # WEBUI_DEFAULT_USER_ROLE: "admin"
    volumes:
      - open-webui-data:/app/backend/data
    networks:
      - ollama-network            # Use custom network
    depends_on:
      - ollama                    # Wait for Ollama to start
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
```

### 1.3 Create Named Volume

Add to the `volumes:` section (top-level):

```yaml
volumes:
  open-webui-data:
    driver: local
```

### 1.4 Update Ollama Service (Optional networking)

Add to the Ollama service:

```yaml
  ollama:
    # ... existing config ...
    networks:
      - ollama-network            # Add this line
```

### 1.5 Add Custom Network Definition

Update the `networks:` section:

```yaml
networks:
  ollama-network:
    driver: bridge
```

### 1.6 Final docker-compose.yml Structure

```yaml
version: '3.8'

services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "0.0.0.0:11434:11434"              # accessible from any IP address
    volumes:
      - /home/bthek1/ollama_doc/models:/root/.ollama/models
    environment:
      OLLAMA_NUM_PARALLEL: "1"
      OLLAMA_MAX_LOADED_MODELS: "2"
      OLLAMA_FLASH_ATTENTION: "1"
      OLLAMA_KEEP_ALIVE: "10m"
      OLLAMA_ORIGINS: "http://localhost:3000,http://127.0.0.1:3000,http://0.0.0.0:3000,http://localhost:8000,http://127.0.0.1:8000,http://0.0.0.0:8000"
    devices:
      - "nvidia.com/gpu=all"
    networks:
      - ollama-network
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s

  ollama-init:
    image: ollama/ollama:latest
    container_name: ollama-init
    depends_on:
      ollama:
        condition: service_healthy
    environment:
      OLLAMA_HOST: "http://ollama:11434"
    volumes:
      - ./Modelfile:/tmp/Modelfile:ro
    networks:
      - ollama-network
    entrypoint: >
      sh -c "
        ollama pull qwen2.5:3b &&
        ollama create analysis-assistant -f /tmp/Modelfile
      "
    restart: "no"

  open-webui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "0.0.0.0:3000:8080"                # accessible from any IP address
    environment:
      OLLAMA_API_BASE_URL: "http://ollama:11434"
      OLLAMA_SHOW_ADMIN_DETAILS: "True"
      SCOPED_MODEL_PERMISSIONS: "True"
      WEBUI_SECRET_KEY: "your-secure-random-key-here"
    volumes:
      - open-webui-data:/app/backend/data
    networks:
      - ollama-network
    depends_on:
      ollama:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

volumes:
  open-webui-data:
    driver: local

networks:
  ollama-network:
    driver: bridge
```

---

## Phase 2: Update OLLAMA_ORIGINS

The `OLLAMA_ORIGINS` setting controls which domains can make requests to the Ollama API. Since you're now exposing on all IP addresses, configure it to accept requests from any source:

```bash
OLLAMA_ORIGINS: "http://localhost:3000,http://127.0.0.1:3000,http://0.0.0.0:3000,http://localhost:8000,http://127.0.0.1:8000,http://0.0.0.0:8000"
```

Or, for unrestricted access (less secure but more flexible):

```bash
OLLAMA_ORIGINS: "*"
```

This allows CORS requests from:
- Open WebUI on localhost (port 3000)
- Open WebUI on any IP address (port 3000)
- Your existing services (port 8000)

---

## Phase 3: Start the Stack

### 3.1 Stop Current Stack (if running)

```bash
just down
# or: docker compose down
```

### 3.2 Update docker-compose.yml

Replace your current file with the updated version above.

### 3.3 Start All Services

```bash
just up
# or: docker compose up -d
```

### 3.4 Verify All Services

```bash
docker compose ps
```

Expected output:
```
CONTAINER ID   IMAGE                                    STATUS              PORTS
xxxxx          ollama/ollama:latest                     Up (healthy)        ...
xxxxx          ollama/ollama:latest                     Exited              ...
xxxxx          ghcr.io/open-webui/open-webui:latest     Up (healthy)        ...
```

### 3.5 Check Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f open-webui
docker compose logs -f ollama
```

---

## Phase 4: Access Open WebUI

### 4.1 Local Access

```
http://localhost:3000
```

### 4.2 Network Access

From any device on your network, replace `HOST_IP` with your server's IP address:

```
http://HOST_IP:3000
```

**Example IPs:**
- `http://192.168.2.28:3000` (LAN)
- `http://10.0.0.5:3000` (Different subnet)
- `http://203.0.113.45:3000` (Public IP, if forwarded)

### 4.3 First Login

1. **First User = Admin**: The first user to register becomes the admin
2. Create username and password
3. Set admin credentials for future access
4. Configure profile settings

---

## Phase 5: Configuration & Customization

### 5.1 Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `OLLAMA_API_BASE_URL` | Ollama API endpoint (internal Docker DNS) | `http://ollama:11434` |
| `WEBUI_SECRET_KEY` | Session encryption key (change this!) | `your-key` |
| `OLLAMA_SHOW_ADMIN_DETAILS` | Show model details in admin panel | `True` |
| `SCOPED_MODEL_PERMISSIONS` | Limit models per user | `True` |
| `WEBUI_PORT` | WebUI internal port | `8080` |
| `TZ` | Timezone | system default |

### 5.2 Security Considerations ⚠️

**IMPORTANT**: Exposing on `0.0.0.0` makes services accessible from any IP address (LAN and internet if port-forwarded).

- **Change WEBUI_SECRET_KEY**: Generate a secure random key:
  ```bash
  python3 -c "import secrets; print(secrets.token_urlsafe(32))"
  ```

- **Firewall Protection**: Configure your firewall/router to restrict access:
  - Only allow trusted networks/IPs
  - Block ports 3000 and 11434 from untrusted sources
  - Use port forwarding only if necessary
  
- **Authentication**: 
  - Enable user registration restrictions
  - Use strong passwords
  - Set `SCOPED_MODEL_PERMISSIONS: "True"` to limit model access per user
  
- **Network Interface Binding**: For more granular control, bind to specific IPs:
  ```yaml
  # Localhost + LAN only (secure)
  ports:
    - "127.0.0.1:3000:8080"
    - "192.168.2.28:3000:8080"
  
  # Localhost + all local interfaces (less restrictive)
  ports:
    - "127.0.0.1:3000:8080"
    - "0.0.0.0:3000:8080"
  ```

- **HTTPS/Reverse Proxy**: For production, use nginx/Caddy with TLS:
  ```nginx
  upstream ollama {
    server localhost:11434;
  }
  
  server {
    listen 443 ssl http2;
    server_name your-domain.com;
    ssl_certificate /etc/ssl/certs/your-cert.pem;
    ssl_certificate_key /etc/ssl/private/your-key.pem;
    
    location / {
      proxy_pass http://localhost:3000;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
    }
  }
  ```

- **Monitor Access Logs**: Check for unauthorized access attempts
  ```bash
  docker compose logs open-webui | grep "ERROR\|WARN"
  ```

### 5.3 Update justfile (Optional)

Add convenient commands to your `justfile`:

```justfile
# Open WebUI logs
[group('Open WebUI')]
webui-logs:
    docker compose logs -f open-webui

# Open WebUI shell
[group('Open WebUI')]
webui-shell:
    docker exec -it open-webui sh

# Access Open WebUI
[group('Open WebUI')]
open-webui:
    @echo "Open WebUI: http://localhost:3000"
```

---

## Phase 6: Using Open WebUI

### 6.1 Chat Interface

1. Navigate to http://localhost:3000
2. Select a model from the dropdown
3. Type your message and press Enter
4. View streaming responses

### 6.2 Model Selection

- Default models: `qwen2.5:3b` and `analysis-assistant`
- All Ollama models appear automatically
- Switch models mid-conversation

### 6.3 Features

- **Conversation History**: Auto-saved locally
- **Export**: Download conversations as JSON/Markdown
- **Parameters**: Adjust temperature, top-p, etc.
- **System Prompt**: Customize model behavior
- **Web Search**: (if configured)

### 6.4 Document Upload (RAG)

1. Click the attachment icon
2. Upload documents (PDF, TXT, etc.)
3. Ask questions about the content
4. WebUI feeds context to the model

---

## Troubleshooting

### Issue: Open WebUI cannot connect to Ollama

**Symptoms**: Error "Failed to connect to Ollama API"

**Solutions**:
1. Check `OLLAMA_API_BASE_URL` is correct: `http://ollama:11434`
2. Verify Ollama container is running: `docker compose ps ollama`
3. Check network connectivity: `docker exec open-webui curl http://ollama:11434/api/tags`
4. View Ollama logs: `docker compose logs ollama`

### Issue: CORS errors in browser console

**Symptoms**: "Cross-Origin Request Blocked"

**Solutions**:
1. Verify `OLLAMA_ORIGINS` includes Open WebUI ports
2. Restart Ollama after updating origins: `docker compose restart ollama`
3. Check browser console for exact origin being blocked

### Issue: Open WebUI startup fails

**Symptoms**: Container exits with error

**Solutions**:
1. Check logs: `docker compose logs open-webui`
2. Verify disk space: `docker volume ls` and `df -h`
3. Inspect container: `docker exec open-webui ls -la /app/backend/data`
4. Reset database by removing volume: `docker volume rm open-webui-data`

### Issue: No models appear in Open WebUI

**Symptoms**: Empty model list

**Solutions**:
1. Verify models are pulled: `docker exec ollama ollama list`
2. Check OLLAMA_API_BASE_URL setting
3. Restart both services: `docker compose restart`
4. Check for network connectivity between containers

### Issue: Slow response times

**Symptoms**: Delays between prompts

**Solutions**:
1. Check GPU passthrough: `nvidia-smi` inside container
2. Reduce `OLLAMA_NUM_PARALLEL` (currently 1)
3. Increase `OLLAMA_KEEP_ALIVE` time
4. Monitor system resources: `docker stats`

---

## Backup & Recovery

### Backup OpenWebUI Data

```bash
# Backup the data volume
docker run --rm -v open-webui-data:/data -v $(pwd):/backup alpine tar czf /backup/open-webui-backup.tar.gz /data

# Restore from backup
docker volume rm open-webui-data
docker run --rm -v open-webui-data:/data -v $(pwd):/backup alpine tar xzf /backup/open-webui-backup.tar.gz -C /
```

### Clear All Data (Reset)

```bash
# Stop and remove
docker compose down open-webui

# Remove volume
docker volume rm open-webui-data

# Restart
docker compose up -d open-webui
```

---

## Next Steps

1. ✅ Update `docker-compose.yml` with Open WebUI service
2. ✅ Verify OLLAMA_ORIGINS includes new ports
3. ✅ Generate secure WEBUI_SECRET_KEY
4. ✅ Start services: `docker compose up -d`
5. ✅ Access http://localhost:3000
6. ✅ Create admin account (first user)
7. ✅ Test model interactions
8. ✅ (Optional) Add convenience commands to justfile
9. ✅ (Optional) Configure HTTPS with reverse proxy
10. ✅ (Optional) Set up user roles and permissions

---

## References

- **Open WebUI Docs**: https://docs.openwebui.com/
- **Open WebUI GitHub**: https://github.com/open-webui/open-webui
- **Ollama Docker Setup**: https://github.com/ollama/ollama/blob/main/docs/docker.md
- **Docker Compose Documentation**: https://docs.docker.com/compose/

---

## Summary

The enhanced Docker setup now includes:
- **Ollama**: Local LLM inference engine (port 11434)
- **Open WebUI**: User-friendly web interface (port 3000)
- **Custom Network**: Seamless service communication
- **Volume Persistence**: Open WebUI database and configuration
- **Health Checks**: Automatic service monitoring
- **GPU Support**: NVIDIA GPU passthrough for both services

**Total Setup Time**: ~5 minutes (after first image pull)
**Disk Space Required**: ~2GB (models) + 500MB (WebUI)
