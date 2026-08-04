# proxmox-ollama

Terraform + Ansible infrastructure for running Ollama on a Proxmox LXC container with NVIDIA GPU passthrough.

**Target:** LXC 202 — `192.168.2.202` — NVIDIA GeForce RTX 3060 (12 GB VRAM) — 4 cores / 8 GB RAM / 80 GB on the `nvme4tb-lvm` pool (4 TB NVMe)

---

## Stack

| Layer       | Tool      | Purpose                                                    |
|-------------|-----------|------------------------------------------------------------|
| Provision   | SSH + pct | Create privileged LXC container 202 on Proxmox             |
| Configure   | Ansible   | Install NVIDIA userspace libs, Ollama, Open WebUI, AnythingLLM |
| Task runner | just      | Wrap common SSH/Ansible ops                                |
| Dev tooling | uv        | Python 3.12 environment for local API testing              |

> **Note:** `just provision` uses `pct create` over SSH — not `terraform apply`. Proxmox API tokens cannot create privileged containers even as `root@pam`, so Terraform is used for config documentation only.

### Services on LXC 202

| Service       | Port  | URL                              |
|---------------|-------|----------------------------------|
| Ollama API    | 11434 | `http://192.168.2.202:11434`     |
| Open WebUI    | 3000  | `http://192.168.2.202:3000`      |
| AnythingLLM   | 3001  | `http://192.168.2.202:3001`      |

### Models on LXC 202

| Model | Size | Purpose |
|-------|------|---------|
| `qwen2.5:3b` | 1.93 GB | Default generation model |
| `qwen3:8b` | 5.23 GB | Larger generation model (tools + thinking) |
| `nomic-embed-text` | 0.27 GB | Embeddings (768-dim vectors, used by AnythingLLM RAG) |

---

## Quick Start

```bash
# 1. Fill in Proxmox credentials
cp terraform/vm202-ollama/secrets.auto.tfvars.example \
   terraform/vm202-ollama/secrets.auto.tfvars
# Edit secrets.auto.tfvars — set proxmox_api_token_secret

# 2. Create LXC container 202 (via pct over SSH)
just provision

# 3. Patch GPU device mounts into /etc/pve/lxc/202.conf (run once after provision)
just gpu-passthrough

# 4. Install NVIDIA libs, Ollama, Open WebUI, AnythingLLM
just deploy

# 5. Verify
just test-api
```

---

## Repository Layout

```
proxmox_ollama/
├── ansible/
│   ├── inventory/hosts.yml
│   ├── group_vars/ollama_hosts/
│   │   ├── vars.yml          # non-secret config (models, ports, driver version)
│   │   └── vault.yml         # secrets placeholder (not yet encrypted)
│   ├── roles/
│   │   ├── nvidia_userspace/ # installs userspace libs matching host driver 595.71.05
│   │   ├── ollama/           # Ollama binary, systemd service, model pull
│   │   ├── open_webui/       # Docker container on port 3000
│   │   └── anything_llm/     # Docker container on port 3001
│   └── site.yml
├── terraform/
│   └── vm202-ollama/
│       ├── provider.tf
│       ├── variables.tf
│       ├── main.tf           # documents intended LXC config
│       ├── outputs.tf
│       ├── secrets.auto.tfvars.example
│       └── terraform.tfvars.example
├── scripts/
│   ├── test_ollama.py        # Ollama API test client (health, models, generate, chat, embeddings)
│   └── lxc-202-gpu.conf      # LXC conf lines appended by just gpu-passthrough
├── docs/
│   ├── ollama-api-reference.md
│   ├── llm-pipelines.md
│   ├── proxmox-lxc-terraform-guide.md
│   └── plans/Completed/
│       ├── lxc-gpu-passthrough.md       # completed plan + lessons learned
│       ├── migrate-to-terraform-ansible.md
│       └── uv-ollama-test-client.md     # completed plan + lessons learned
├── pyproject.toml            # uv project (proxmox-ollama-tools, Python 3.12)
├── uv.lock                   # pinned dependencies
├── justfile
└── CLAUDE.md
```

---

## Prerequisites

- Ansible >= 2.14
- `just` task runner
- `uv` — Python package manager ([install](https://docs.astral.sh/uv/getting-started/installation/))
- SSH key at `~/.ssh/id_ed25519` (injected into container root at provision time)
- SSH alias `proxmox` → `ben@192.168.2.70` configured in `~/.ssh/config`

---

## Common Commands

```bash
just provision          # create LXC container 202 via pct over SSH
just gpu-passthrough    # append GPU + AppArmor config to /etc/pve/lxc/202.conf, restart container
just deploy             # run ansible-playbook site.yml (no vault password needed)
just deploy-check       # dry run (--check --diff)
just test-api           # run Ollama API test suite — health, models, generate, stream, chat, embeddings
just models             # list downloaded models and sizes
just pull mistral       # pull a model by name
just logs               # tail Ollama systemd logs
just gpu                # nvidia-smi on container 202
just ssh                # SSH into container 202 as root
just ct-stop            # stop LXC container 202
just ct-start           # start LXC container 202
```

### API test client

```bash
just test-api                                   # defaults: qwen2.5:3b + nomic-embed-text
MODEL=qwen3:8b just test-api                    # use a different generation model
EMBED_MODEL=mxbai-embed-large just test-api     # use a different embedding model
```

---

## Credentials

**Proxmox API token** (`secrets.auto.tfvars`, gitignored):
```hcl
proxmox_api_token_id     = "root@pam!terraform"
proxmox_api_token_secret = "..."
```
Token must belong to `root@pam` — other users are blocked from privileged container operations.

**Ansible secrets** (`vault.yml`): not currently encrypted. WebUI admin credentials are hardcoded in `group_vars/ollama_hosts/vars.yml` and should be moved to a proper vault before exposing services externally.

---

## Known Gotchas

| Issue | Fix applied |
|---|---|
| Proxmox API token cannot create privileged containers | `just provision` uses `pct create` via SSH instead of `terraform apply` |
| Docker blocked by AppArmor inside privileged LXC | `lxc.apparmor.profile: unconfined` in LXC conf + `--security-opt apparmor=unconfined` in each `docker run` |
| Ollama install script needs `zstd` | Added as apt prerequisite in the `ollama` role |
| AnythingLLM SQLite can't write to mounted volume | Storage dir created with `mode: 0777` |
| `just` heredocs can't contain `lxc.*` lines | GPU config lives in `scripts/lxc-202-gpu.conf`, applied via `scp` |
| Ollama 0.30.2 doesn't support embeddings for chat models | Use `nomic-embed-text` — a dedicated embedding model that works correctly |
| `ssh proxmox "pct ..."` fails with `command not found` / `ipcc_send_rec failed` | Non-login SSH has no `/usr/sbin` on PATH and pmxcfs needs root — use `ssh proxmox "sudo /usr/sbin/pct ..."` |
| Container `nvidia-smi` reports `Driver/library version mismatch` | apt's `nvidia-utils-595` drifts to the newest 595.x (`595.84`) while the host module stays `595.71.05` — the `nvidia_userspace` role purges the apt packages and installs the exact `.run` userspace with `--no-kernel-modules` |

---

## Reference

- [Ollama API Reference](docs/ollama-api-reference.md) — connection details, endpoints, Python/JS/LangChain examples
- [LLM Pipeline Patterns](docs/llm-pipelines.md) — direct inference, chat, RAG, agents, chaining, map-reduce with ASCII diagrams
- [LXC GPU Passthrough Plan](docs/plans/Completed/lxc-gpu-passthrough.md) — completed, full lessons learned
- [uv + Ollama API Client Plan](docs/plans/Completed/uv-ollama-test-client.md) — completed, embedding gotcha explained
- [Proxmox LXC Terraform Guide](docs/proxmox-lxc-terraform-guide.md)
