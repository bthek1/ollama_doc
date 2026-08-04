variable "proxmox_endpoint" {
  description = "Proxmox API endpoint (e.g. https://192.168.2.70:8006)"
  type        = string
  default     = "https://192.168.2.70:8006"
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID — must be root@pam to create privileged containers (e.g. root@pam!terraform)"
  type        = string
  default     = "root@pam!terraform"
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret UUID"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name to create the container on"
  type        = string
  default     = "bthek1"
}

variable "vm_id" {
  description = "Proxmox container ID"
  type        = number
  default     = 202
}

variable "vm_name" {
  description = "Container hostname"
  type        = string
  default     = "ollama-202"
}

variable "template_file_id" {
  description = "LXC template file ID on Proxmox (e.g. local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)"
  type        = string
}

variable "cores" {
  description = "Number of vCPU cores"
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "RAM in MB"
  type        = number
  default     = 8192 # 8 GB
}

variable "disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 80
}

variable "datastore" {
  description = "Proxmox storage pool for the disk"
  type        = string
  default     = "nvme4tb-lvm"
}

variable "ip_address" {
  description = "Static IPv4 address with prefix (CIDR)"
  type        = string
  default     = "192.168.2.202/24"
}

variable "gateway" {
  description = "Default gateway"
  type        = string
  default     = "192.168.2.1"
}

variable "dns_servers" {
  description = "DNS servers"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_public_key" {
  description = "SSH public key to inject into the container"
  type        = string
}
