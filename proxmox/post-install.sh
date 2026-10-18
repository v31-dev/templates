#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration Variables ---
SNIPPET_DIR="/var/lib/vz/snippets"
SNIPPET_FILE="$SNIPPET_DIR/ubuntu-setup.yaml"
ISO_DIR="/var/lib/vz/template/iso"

# --- Define Virtual Machines to Build ---
# Format: "VM_ID:VM_NAME:IMAGE_FILE_NAME:IMAGE_URL"
VMS=(
  "9000:ubuntu-24.04-cloud:noble-server-cloudimg-amd64.img:https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  "9001:ubuntu-26.04-cloud:resolute-server-cloudimg-amd64.img:https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
)

echo "=== Proxmox Infrastructure Builder ==="

# 1. Securely ask for the root password
read -s -p "Enter the desired root password for your templates: " ROOT_PASS
echo -e "\n"

# 2. Configure Storage
echo "[1/5] Enabling Snippet Storage..."
pvesm set local --content backup,iso,vztmpl,snippets || true

# 3. Download Cloud Images (Idempotent: Checks if file exists)
echo "[2/5] Syncing Cloud Images..."
mkdir -p "$ISO_DIR"

for vm_def in "${VMS[@]}"; do
    IFS=':' read -r VM_ID VM_NAME IMG_FILE IMG_URL <<< "$vm_def"
    TARGET_PATH="$ISO_DIR/$IMG_FILE"
    
    if [ ! -f "$TARGET_PATH" ]; then
        echo " -> Downloading $IMG_FILE..."
        wget -q --show-progress -O "$TARGET_PATH" "$IMG_URL"
    else
        echo " -> $IMG_FILE already exists. Skipping download."
    fi
done

# 4. Create the Cloud-Init Snippet (Idempotent: Overwrites with the latest configuration)
echo "[3/5] Generating Cloud-Init Snippet..."
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
- curl -fsSL https://tailscale.com/install.sh | sh
- touch /etc/cloud/cloud-init.disabled

power_state:
  mode: reboot
  timeout: 10
  condition: True
EOF

# 5. Build VMs in a Loop (Idempotent: Skips if VM ID already exists)
echo "[4/5] Building Virtual Machine Templates..."

for vm_def in "${VMS[@]}"; do
    IFS=':' read -r VM_ID VM_NAME IMG_FILE IMG_URL <<< "$vm_def"
    
    # Check if VM already exists
    if qm status $VM_ID >/dev/null 2>&1; then
        echo " -> VM/Template $VM_ID ($VM_NAME) already exists. Skipping creation."
        continue
    fi
    
    echo " -> Setting up $VM_NAME (ID: $VM_ID)..."

    # Core architecture and console
    qm create $VM_ID --name $VM_NAME --machine q35 --agent 1 --scsihw virtio-scsi-single --serial0 socket --vga serial0

    # Resources (2 Cores, 4GB RAM)
    qm set $VM_ID --memory 4096 --balloon 1 --cores 2 --cpu host

    # Network
    qm set $VM_ID --net0 virtio,bridge=vmbr0

    # Disk Import using the specific image for this template
    qm set $VM_ID --scsi0 local-lvm:0,import-from="$ISO_DIR/$IMG_FILE",discard=on,ssd=1,iothread=1
    qm set $VM_ID --ide2 local-lvm:cloudinit

    # Boot Order, Cloud-Init, and Power Settings
    qm set $VM_ID --boot order=scsi0
    qm set $VM_ID --ipconfig0 ip=dhcp,ip6=dhcp
    qm set $VM_ID --onboot 1

    # Attach Snippet and Convert
    qm set $VM_ID --cicustom "vendor=local:snippets/ubuntu-setup.yaml"
    qm template $VM_ID
    
    echo " -> $VM_NAME setup complete!"
done

# 6. Install Monitoring
echo "[5/5] Installing Host Monitoring Tools..."
apt-get update
apt-get install -y btop s-tui lm-sensors stress
sensors-detect --auto || true

echo "=== Launching Community Post-Install Script ==="
bash <(curl -s https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)
