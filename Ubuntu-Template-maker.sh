#!/bin/bash

set -e

# -------------------------------
# Config
# -------------------------------
STORAGE="local-lvm"
BRIDGE="vmbr0"
DEFAULT_USER="ubuntu"
TEMPLATE_START_VMID=9001
MIN_IMAGE_SIZE=10000000  # 10MB

# -------------------------------
# Ubuntu Cloud Image Base URL
# -------------------------------
BASE_URL="https://cloud-images.ubuntu.com/releases"

# -------------------------------
# Get available Ubuntu versions
# -------------------------------
echo "🔍 Fetching available Ubuntu versions..."
AVAILABLE_VERSIONS=$(curl -s "$BASE_URL/" | grep -oP 'href="\K[0-9]+\.[0-9]+(?=/")' | sort -Vu)

echo "📦 Available Ubuntu versions:"
echo "$AVAILABLE_VERSIONS" | sed 's/^/  - /'

# -------------------------------
# Get version from user
# -------------------------------
read -p "Enter Ubuntu version (e.g., 22.04): " VERSION

# Validate version
if ! echo "$AVAILABLE_VERSIONS" | grep -qx "$VERSION"; then
  echo "❌ Invalid Ubuntu version: $VERSION"
  exit 1
fi

# -------------------------------
# Prepare image details
# -------------------------------
IMAGE_FILE="ubuntu-${VERSION}-server-cloudimg-amd64.img"
IMAGE_URL="$BASE_URL/$VERSION/release/$IMAGE_FILE"

# -------------------------------
# Skip download if already exists
# -------------------------------
if [[ -f "$IMAGE_FILE" ]]; then
  FILE_SIZE=$(stat -c %s "$IMAGE_FILE")
  if [[ $FILE_SIZE -lt $MIN_IMAGE_SIZE ]]; then
    echo "⚠️ Image seems corrupted or incomplete. Re-downloading..."
    rm -f "$IMAGE_FILE"
  else
    echo "✅ Image already exists: $IMAGE_FILE"
  fi
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
  echo "⬇️ Downloading $IMAGE_FILE..."
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
# Generate random password
# -------------------------------
DEFAULT_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+=' </dev/urandom | head -c 16)
echo "🔐 Generated password for user '$DEFAULT_USER': $DEFAULT_PASSWORD"

# -------------------------------
# Get next available VMID
# -------------------------------
get_next_vmid() {
  local start=$TEMPLATE_START_VMID
  local used_vmids=$(pvesh get /cluster/resources --type vm --output-format json | jq -r '.[].vmid' | sort -n)
  local vmid=$start

  while echo "$used_vmids" | grep -qx "$vmid"; do
    ((vmid++))
  done

  echo "$vmid"
}

VMID=$(get_next_vmid)
echo "🆔 Using VMID: $VMID"

# -------------------------------
# Create VM
# -------------------------------
qm create $VMID \
  --name ubuntu-${VERSION}-template \
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
# Import disk
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
echo -e "\n✅ Ubuntu $VERSION Cloud-Init template created!"
echo "   ➤ VMID: $VMID"
echo "   ➤ User: $DEFAULT_USER"
echo "   ➤ Password: $DEFAULT_PASSWORD"
