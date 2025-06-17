#!/bin/bash

set -e

# -------------------------------
# Config
# -------------------------------
STORAGE="local-lvm"
BRIDGE="vmbr0"
DEFAULT_USER="centos"
TEMPLATE_START_VMID=9001
MIN_IMAGE_SIZE=10000000  # 10MB minimum size check

# -------------------------------
# Image URLs
# -------------------------------
declare -A IMAGE_URLS
declare -A IMAGE_FILES

IMAGE_URLS["7"]="https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2"
IMAGE_FILES["7"]="CentOS-7-x86_64-GenericCloud.qcow2"

IMAGE_URLS["8"]="https://cloud.centos.org/centos/8/x86_64/images/CentOS-8-GenericCloud-8.5.2111-20220125.0.x86_64.qcow2"
IMAGE_FILES["8"]="CentOS-8-GenericCloud.qcow2"

IMAGE_URLS["stream8"]="https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-20220125.0.x86_64.qcow2"
IMAGE_FILES["stream8"]="CentOS-Stream-8.qcow2"

IMAGE_URLS["stream9"]="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-20240207.0.x86_64.qcow2"
IMAGE_FILES["stream9"]="CentOS-Stream-9.qcow2"

# -------------------------------
# Helper: Get next unused VMID
# -------------------------------
get_next_vmid() {
    local start=${TEMPLATE_START_VMID:-9001}
    local existing_vmids=$(pvesh get /cluster/resources --type vm --output-format json | jq -r '.[].vmid' | sort -n)
    local vmid=$start

    while echo "$existing_vmids" | grep -qx "$vmid"; do
        ((vmid++))
    done

    echo "$vmid"
}

# -------------------------------
# Helper: Print supported versions
# -------------------------------
print_versions() {
    echo "📦 Supported CentOS Versions:"
    echo "  - 7"
    echo "  - 8"
    echo "  - stream8"
    echo "  - stream9"
}

# -------------------------------
# Prompt for version
# -------------------------------
print_versions
read -p "Enter CentOS version (7, 8, stream8, stream9): " VERSION

if [[ -z "${IMAGE_URLS[$VERSION]}" ]]; then
    echo "❌ Unsupported version."
    exit 1
fi

IMAGE_URL="${IMAGE_URLS[$VERSION]}"
IMAGE_FILE="${IMAGE_FILES[$VERSION]}"

# -------------------------------
# Download image (skip if valid)
# -------------------------------
if [[ -f "$IMAGE_FILE" ]]; then
    FILE_SIZE=$(stat -c %s "$IMAGE_FILE")
    if [[ $FILE_SIZE -lt $MIN_IMAGE_SIZE ]]; then
        echo "⚠️ Existing image is too small, redownloading..."
        rm -f "$IMAGE_FILE"
    else
        echo "✅ Image already exists and is valid: $IMAGE_FILE"
    fi
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "⬇️ Downloading CentOS $VERSION image..."
    curl -L -o "$IMAGE_FILE" "$IMAGE_URL"
fi

# -------------------------------
# SSH key input
# -------------------------------
read -p "Use default SSH key at ~/.ssh/id_rsa.pub? [Y/n]: " USE_DEFAULT
USE_DEFAULT=${USE_DEFAULT:-Y}

if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
    if [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
        SSH_KEY=$(cat "$HOME/.ssh/id_rsa.pub")
    else
        echo "❌ SSH key not found at ~/.ssh/id_rsa.pub"
        exit 1
    fi
else
    read -p "Paste your SSH public key: " SSH_KEY
    if [[ -z "$SSH_KEY" ]]; then
        echo "❌ SSH key cannot be empty."
        exit 1
    fi
fi

# -------------------------------
# Generate password
# -------------------------------
DEFAULT_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+=' </dev/urandom | head -c 16)
echo "🔐 Generated password for user '$DEFAULT_USER': $DEFAULT_PASSWORD"

# -------------------------------
# Allocate next VMID
# -------------------------------
VMID=$(get_next_vmid)
echo "🆔 Using VMID: $VMID"

# -------------------------------
# Create VM
# -------------------------------
qm create $VMID \
  --name centos-${VERSION}-template \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=$BRIDGE \
  --serial0 socket \
  --vga serial0 \
  --ciuser $DEFAULT_USER \
  --cipassword "$DEFAULT_PASSWORD" \
  --sshkey <(echo "$SSH_KEY") \
  --ostype l26

# -------------------------------
# Import and attach disk
# -------------------------------
qm importdisk $VMID "$IMAGE_FILE" "$STORAGE" --format qcow2
qm set $VMID --scsihw virtio-scsi-pci --scsi0 "$STORAGE:vm-$VMID-disk-0"
qm set $VMID --ide2 "$STORAGE:cloudinit"
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --ipconfig0 ip=dhcp

# -------------------------------
# Convert to template
# -------------------------------
qm template $VMID

# -------------------------------
# Done
# -------------------------------
echo -e "\n✅ CentOS $VERSION Cloud-Init template created!"
echo "   ➤ VMID: $VMID"
echo "   ➤ User: $DEFAULT_USER"
echo "   ➤ Password: $DEFAULT_PASSWORD"
