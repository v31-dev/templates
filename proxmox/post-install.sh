#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration Variables ---
VM_ID=9000
VM_NAME="ubuntu-cloud-base"
SNIPPET_DIR="/var/lib/vz/snippets"
SNIPPET_FILE="$SNIPPET_DIR/ubuntu-setup.yaml"
ISO_DIR="/var/lib/vz/template/iso"

# --- ISO & Image List Here ---
declare -A ISO_LIST=(
  ["noble-server-cloudimg-amd64.img"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  ["resolute-server-cloudimg-amd64.img"]="https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
)

echo "=== Proxmox Infrastructure Builder ==="

# 1. Securely ask for the root password
read -s -p "Enter the desired root password for your template: " ROOT_PASS
echo -e "\n"

# 2. Configure Storage
echo "[1/7] Enabling Snippet Storage..."
pvesm set local --content backup,iso,vztmpl,snippets

# 3. Download ISOs and Cloud Images
echo "[2/7] Syncing ISOs and Cloud Images..."
mkdir -p "$ISO_DIR"

for FILENAME in "${!ISO_LIST[@]}"; do
    URL="${ISO_LIST[$FILENAME]}"
    TARGET_PATH="$ISO_DIR/$FILENAME"
    
    if [ ! -f "$TARGET_PATH" ]; then
        echo " -> Downloading $FILENAME..."
        wget -q --show-progress -O "$TARGET_PATH" "$URL"
    else
        echo " -> $FILENAME already exists. Skipping."
    fi
done

# 4. Create the Cloud-Init Snippet
echo "[3/7] Generating Cloud-Init Snippet..."
mkdir -p $SNIPPET_DIR

cat <<EOF > $SNIPPET_FILE
#cloud-config
package_update: true
package_upgrade: true

packages:
  - qemu-guest-agent
  - curl

chpasswd:
  list: |
    root:$ROOT_PASS
  expire: false

runcmd:
  - systemctl enable --now qemu-guest-agent
  - touch /etc/cloud/cloud-init.disabled
EOF

# 5. Clean up old template if it exists
echo "[4/7] Cleaning up old VM $VM_ID (if it exists)..."
qm destroy $VM_ID 2>/dev/null || true

# 6. Build the VM Hardware
echo "[5/7] Creating Virtual Machine..."

# Core architecture and console
qm create $VM_ID --name $VM_NAME --machine q35 --agent 1 --scsihw virtio-scsi-single --serial0 socket --vga serial0

# Resources (2 Cores, 4GB RAM)
qm set $VM_ID --memory 4096 --balloon 1 --cores 2 --cpu host

# Network
qm set $VM_ID --net0 virtio,bridge=vmbr0

# Disk Import
qm set $VM_ID --scsi0 local-lvm:0,import-from="$ISO_DIR/noble-server-cloudimg-amd64.img",discard=on,ssd=1,iothread=1
qm set $VM_ID --ide2 local-lvm:cloudinit

# Boot Order, Cloud-Init, and Power Settings
qm set $VM_ID --boot order=scsi0
qm set $VM_ID --ipconfig0 ip=dhcp,ip6=dhcp
qm set $VM_ID --onboot 1

# 7. Attach Snippet and Convert
echo "[6/7] Attaching Cloud-Init Snippet and Converting..."
qm set $VM_ID --cicustom "vendor=local:snippets/ubuntu-setup.yaml"
qm template $VM_ID

# 8. Install Monitoring & Launch Interactive Script
echo "[7/7] Installing Monitoring Tools..."
apt-get update
apt-get install -y btop s-tui lm-sensors stress
sensors-detect --auto

echo "=== Launching Community Post-Install Script ==="
bash <(curl -s https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)
