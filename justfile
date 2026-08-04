OLLAMA_HOST := "192.168.2.202"
OLLAMA_URL  := "http://" + OLLAMA_HOST + ":11434"
SSH_USER    := "root"
TF_DIR      := "terraform/vm202-ollama"
ANSIBLE_DIR := "ansible"
MODEL       := "qwen2.5:3b"

# Show available commands
default:
    @just --list

# ── Terraform ───────────────────────────────────────────────────────────────

# Initialise Terraform (run once)
[group('Terraform')]
tf-init:
    cd {{TF_DIR}} && terraform init

# Preview infrastructure changes
[group('Terraform')]
tf-plan:
    cd {{TF_DIR}} && terraform plan

SSH_PUBKEY := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPv/mGCYJ3q949/gsm90nbMs9Cq7FOhVGmWfmf5MDwbT rag"

# Create LXC container 202 directly via pct (Proxmox API tokens cannot create privileged containers)
[group('Terraform')]
provision:
    ssh proxmox "echo 3719 | sudo -Sp '' bash -c 'echo \"{{SSH_PUBKEY}}\" > /tmp/ollama-202.pub'"
    ssh proxmox "echo 3719 | sudo -Sp '' pct create 202 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
      --hostname ollama-202 \
      --memory 8192 \
      --swap 2048 \
      --cores 4 \
      --net0 name=eth0,bridge=vmbr0,ip=192.168.2.202/24,gw=192.168.2.1 \
      --rootfs nvme4tb-lvm:80 \
      --unprivileged 0 \
      --features nesting=1 \
      --ssh-public-keys /tmp/ollama-202.pub \
      --nameserver '1.1.1.1 8.8.8.8' \
      --onboot 1"
    ssh proxmox "echo 3719 | sudo -Sp '' rm -f /tmp/ollama-202.pub"
    @echo "Container 202 created. Run: just gpu-passthrough && just ct-start"

# Destroy VM 202 (DANGEROUS — prompts for confirmation)
[group('Terraform')]
tf-destroy:
    cd {{TF_DIR}} && terraform destroy

# Show Terraform outputs (IP, SSH command)
[group('Terraform')]
tf-output:
    cd {{TF_DIR}} && terraform output

# ── Ansible ─────────────────────────────────────────────────────────────────

# Test connectivity to VM 202
[group('Ansible')]
ping:
    ansible vm202 -i {{ANSIBLE_DIR}}/inventory/hosts.yml -m ping

# Run the full playbook (installs drivers, Ollama, Open WebUI, AnythingLLM)
[group('Ansible')]
deploy:
    ansible-playbook {{ANSIBLE_DIR}}/site.yml \
        -i {{ANSIBLE_DIR}}/inventory/hosts.yml \
        --ask-vault-pass

# Dry-run the playbook (no changes applied)
[group('Ansible')]
deploy-check:
    ansible-playbook {{ANSIBLE_DIR}}/site.yml \
        -i {{ANSIBLE_DIR}}/inventory/hosts.yml \
        --ask-vault-pass \
        --check --diff

# Run only the ollama role (skip driver install)
[group('Ansible')]
deploy-ollama:
    ansible-playbook {{ANSIBLE_DIR}}/site.yml \
        -i {{ANSIBLE_DIR}}/inventory/hosts.yml \
        --ask-vault-pass \
        --tags ollama

# Run only the open_webui role
[group('Ansible')]
deploy-webui:
    ansible-playbook {{ANSIBLE_DIR}}/site.yml \
        -i {{ANSIBLE_DIR}}/inventory/hosts.yml \
        --ask-vault-pass \
        --tags open_webui

# Edit encrypted vault secrets
[group('Ansible')]
vault-edit:
    ansible-vault edit {{ANSIBLE_DIR}}/group_vars/ollama_hosts/vault.yml

# Patch /etc/pve/lxc/202.conf with NVIDIA device mounts (run once after provision)
# Terraform cannot write raw LXC config lines — must go via SSH on the Proxmox host
[group('Terraform')]
gpu-passthrough:
    scp scripts/lxc-202-gpu.conf proxmox:/tmp/lxc-202-gpu.conf
    ssh proxmox "echo 3719 | sudo -Sp '' bash -c 'cat /tmp/lxc-202-gpu.conf >> /etc/pve/lxc/202.conf && rm /tmp/lxc-202-gpu.conf'"
    ssh proxmox "echo 3719 | sudo -Sp '' pct stop 202 && echo 3719 | sudo -Sp '' pct start 202"
    @echo "GPU passthrough added and container 202 restarted."

# Stop container 202 on Proxmox
[group('Terraform')]
ct-stop:
    ssh proxmox "echo 3719 | sudo -Sp '' pct stop 202"

# Start container 202 on Proxmox
[group('Terraform')]
ct-start:
    ssh proxmox "echo 3719 | sudo -Sp '' pct start 202"

# ── VM 202 Operations ───────────────────────────────────────────────────────

# SSH into VM 202
[group('VM 202')]
ssh:
    ssh {{SSH_USER}}@{{OLLAMA_HOST}}

# Test Ollama API — health, models, generate, stream, chat, embeddings
[group('VM 202')]
test-api model=MODEL:
    MODEL={{model}} uv run python scripts/test_ollama.py

# List all downloaded models on VM 202
[group('VM 202')]
models:
    @curl -s {{OLLAMA_URL}}/api/tags | python3 -c \
        "import json,sys; [print(m['name'], f\"{m.get('size',0)/1e9:.2f}GB\") for m in json.load(sys.stdin).get('models',[])]"

# Pull a model — usage: just pull mistral
[group('VM 202')]
pull model=MODEL:
    ssh {{SSH_USER}}@{{OLLAMA_HOST}} "ollama pull {{model}}"

# Remove a model — usage: just remove mistral
[group('VM 202')]
remove model=MODEL:
    ssh {{SSH_USER}}@{{OLLAMA_HOST}} "ollama rm {{model}}"

# Show GPU stats on VM 202
[group('VM 202')]
gpu:
    ssh {{SSH_USER}}@{{OLLAMA_HOST}} nvidia-smi

# Tail Ollama systemd logs on VM 202
[group('VM 202')]
logs:
    ssh {{SSH_USER}}@{{OLLAMA_HOST}} "journalctl -fu ollama"

# Restart Ollama service on VM 202
[group('VM 202')]
restart-ollama:
    ssh {{SSH_USER}}@{{OLLAMA_HOST}} "sudo systemctl restart ollama"

# Check all service statuses on VM 202
[group('VM 202')]
service-status:
    ssh {{SSH_USER}}@{{OLLAMA_HOST}} "systemctl status ollama open-webui anything-llm"
