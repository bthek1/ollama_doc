# proxmox-ollama — Codebase Guide

## Project Purpose

Terraform + Ansible infrastructure to deploy Ollama (local LLM inference) on **LXC container 202** (`192.168.2.202`) in Proxmox, with NVIDIA GeForce RTX 3060 GPU passthrough via LXC device sharing.

## Target Machine

| Property | Value |
|---|---|
| Container ID | 202 |
| IP | `192.168.2.202` |
| GPU | NVIDIA GeForce RTX 3060 (12 GB VRAM) — shared from Proxmox host driver `595.71.05` |
| OS | Ubuntu 24.04 (LXC, privileged) |
| SSH user | `root` (LXC containers created from template have only root; no ubuntu user) |
| Storage | `nvme4tb-lvm:vm-202-disk-0`, 80 GB — 4 TB Seagate NVMe thin pool (`nvme1n1`) |
| CPU / RAM | 4 cores / 8 GB |

## Services Deployed

| Service       | Port  | Notes                              |
|---------------|-------|------------------------------------|
| Ollama API    | 11434 | Native binary, systemd service     |
| Open WebUI    | 3000  | Browser chat UI                    |
| AnythingLLM   | 3001  | RAG / document chat UI             |

## Key Files

| Path | Purpose |
|---|---|
| `terraform/vm202-ollama/` | Provision LXC container 202 on Proxmox |
| `ansible/site.yml` | Main playbook — runs all roles |
| `ansible/inventory/hosts.yml` | Container 202 host entry |
| `ansible/group_vars/ollama_hosts/vars.yml` | Non-secret config |
| `ansible/group_vars/ollama_hosts/vault.yml` | Secrets placeholder (not currently encrypted) |
| `ansible/roles/nvidia_userspace/` | NVIDIA userspace libs (matches host driver `595.71.05`) |
| `ansible/roles/ollama/` | Ollama binary, systemd, models |
| `ansible/roles/open_webui/` | Open WebUI deployment |
| `ansible/roles/anything_llm/` | AnythingLLM deployment |
| `justfile` | Task runner |
| `scripts/test_ollama.py` | Ollama API test client (health, models, generate, stream, chat, embeddings) |
| `scripts/lxc-202-gpu.conf` | LXC config lines for GPU passthrough + AppArmor (appended by `just gpu-passthrough`) |
| `pyproject.toml` | uv project — Python deps (`ollama`, `httpx`, `rich`) |
| `docs/ollama-api-reference.md` | Ollama HTTP API reference |

## Common Commands

```bash
just provision          # create LXC container via pct over SSH (not terraform apply)
just gpu-passthrough    # patch /etc/pve/lxc/202.conf + restart (run once after provision)
just deploy             # ansible-playbook site.yml
just test-api           # run Ollama API test suite against 192.168.2.202:11434
just gpu                # nvidia-smi on container 202
just ssh                # SSH into container 202
```

## Terraform

- Provider: `bpg/proxmox` ~> 0.75
- Working dir: `terraform/vm202-ollama/`
- **`provision` does NOT use `terraform apply`** — Proxmox API tokens cannot create privileged containers even as `root@pam`. `just provision` runs `pct create` over SSH via sudo instead.
- Terraform files (`variables.tf`, `main.tf`, etc.) document the intended config; state is not managed by Terraform for this container.
- Credentials: `secrets.auto.tfvars` (gitignored) — see `secrets.auto.tfvars.example`
- Token: `root@pam!terraform` (must be root@pam; other users blocked from privileged containers)

## Storage

Container 202 lives on the **4 TB NVMe** (`nvme1n1`, Seagate ZP4000GP304001) in the `nvme4tb-lvm` LVM-thin pool — moved off `local-lvm` so Ollama model files have room to grow.

| Pool | Backing device | Size | Use |
|---|---|---|---|
| `nvme4tb-lvm` | `nvme1n1` (4 TB NVMe) | 3.6 TB | **VM/CT disks, including 202** |
| `local-lvm` | `nvme0n1` (1 TB NVMe) | 794 GB | boot disk pool, mostly unused |
| `local` | `nvme0n1` / `pve-root` | 94 GB | ISOs + LXC templates (`local:vztmpl/...`) |
| `backup-2tb` | `sda` (2 TB HDD) | 1.8 TB | backups |
| `backup` | `sdb` (120 GB SSD) | 112 GB | backups |

- Rootfs: `nvme4tb-lvm:vm-202-disk-0`, 80 GB (~24 GB used, models at `/root/.ollama/models`).
- The LXC **template** still comes from `local:vztmpl/...` — only the rootfs pool changed.
- To move it again: `pct shutdown 202 && pct move-volume 202 rootfs <target-pool>`.

## Ansible

- Inventory: `ansible/inventory/hosts.yml`
- Vault: `ansible/group_vars/ollama_hosts/vault.yml` — **not currently encrypted** (placeholder only); run without `--ask-vault-pass`
- Run with: `ansible-playbook ansible/site.yml -i ansible/inventory/hosts.yml`
- Roles: `nvidia_userspace` → `ollama` → `open_webui` → `anything_llm`
- `nvidia_userspace` installs userspace-only from NVIDIA's `.run` file (`--no-kernel-modules`) pinned to `nvidia_driver_version` — this **must** equal the host driver (`ssh proxmox nvidia-smi`); the role asserts it. Do not switch back to apt's `nvidia-utils-<branch>`, which floats within the branch.
- Docker services use `--security-opt apparmor=unconfined` — required inside privileged LXC

## Known Gotchas

| Issue | Fix |
|---|---|
| Proxmox API token (even `root@pam`) cannot create privileged containers | Use `pct create` over SSH via `just provision` |
| Docker inside LXC blocked by AppArmor | `--security-opt apparmor=unconfined` in each `docker run` + `lxc.apparmor.profile: unconfined` in LXC conf |
| Ollama install script requires `zstd` | Installed as prerequisite in the `ollama` role |
| AnythingLLM SQLite can't write to storage | Storage dir must be `mode: 0777` |
| `gpu-passthrough` heredoc fails in just | Config is in `scripts/lxc-202-gpu.conf`, transferred via `scp` |
| `ssh proxmox "pct ..."` → `pct: command not found`, or `ipcc_send_rec failed` | Non-login SSH lacks `/usr/sbin` on PATH **and** pmxcfs needs root: use `ssh proxmox "sudo /usr/sbin/pct ..."` |
| Container `nvidia-smi` → `Driver/library version mismatch` | apt's `nvidia-utils-595` floats to the newest 595.x (`595.84`) while the host module is `595.71.05`. The `nvidia_userspace` role now purges the apt packages and installs the exact-version `.run` userspace instead |

## Default Model

`qwen2.5:3b` — small, fits in limited VRAM scenarios. Also deployed: `qwen3:8b` (larger generation model, tools + thinking) and `nomic-embed-text` (embeddings for AnythingLLM RAG). Extra models are listed in `ollama_models_extra` in `ansible/group_vars/ollama_hosts/vars.yml`.

## Reference Docs

- [Proxmox LXC Terraform Guide](docs/proxmox-lxc-terraform-guide.md)
- [Ollama API Reference](docs/ollama-api-reference.md)
- [LLM Pipelines](docs/llm-pipelines.md)
- [LXC GPU Passthrough Plan](docs/plans/Completed/lxc-gpu-passthrough.md) — completed, includes lessons learned
- [Migration Plan](docs/plans/Completed/migrate-to-terraform-ansible.md)
