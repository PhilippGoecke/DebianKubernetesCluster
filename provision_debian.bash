#!/bin/bash
set -euo pipefail

# --- ERFORDERLICHE BEFEHLE PRÜFEN ---
REQUIRED_COMMANDS=(wget virsh qemu-img mktemp genisoimage virt-install rm cat)
MISSING_COMMANDS=()
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_COMMANDS+=("$cmd")
  fi
done

if ((${#MISSING_COMMANDS[@]} > 0)); then
  printf 'Fehler: Erforderliche Befehle fehlen: %s\n' "${MISSING_COMMANDS[*]}" >&2
  exit 1
fi

# --- KONFIGURATION ---
VM_NAME="debian-trixie-k8s-singlenode"
RAM_MB=2048
VCPUS=2
DISK_SIZE="20G"
NETWORK="default" # Name des libvirt-Netzwerks (z.B. default oder virbr0)

# Pfade auf dem Host
POOL_DIR="/var/lib/libvirt/images"
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2"
BASE_IMAGE="$POOL_DIR/debian-13-genericcloud-amd64-daily.qcow2"
VM_DISK="$POOL_DIR/${VM_NAME}.qcow2"
SEED_ISO="$POOL_DIR/${VM_NAME}-seed.iso"

# Gast-Betriebssystem Konfiguration
USERNAME="debian"
PASSWORD="SehrSicheresPasswort123!"
SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub" # Wird injiziert, falls vorhanden

echo "=== Starte Provisionierung von $VM_NAME ==="

# 1. Basis-Image herunterladen falls nicht vorhanden
if [ ! -f "$BASE_IMAGE" ]; then
    echo "[*] Lade Debian Trixie Cloud Image herunter..."
    wget -O "$BASE_IMAGE" "$IMAGE_URL"
fi

# 2. Bestehende VM-Reste aufräumen
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "[!] VM $VM_NAME existiert bereits. Lösche alte Instanz..."
    virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    virsh undefine "$VM_NAME" --remove-all-storage || true
fi
rm -f "$VM_DISK" "$SEED_ISO"

# 3. Eigenes VM-Disk-Image erstellen und vergrößern
echo "[*] Erstelle VM-Festplatte ($DISK_SIZE)..."
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_DISK"
qemu-img resize "$VM_DISK" "$DISK_SIZE"

# 4. Cloud-Init Konfigurationen temporär erstellen
echo "[*] Generiere Cloud-Init Konfiguration..."
TEMP_DIR=$(mktemp -d)

# user-data
cat <<EOF > "$TEMP_DIR/user-data"
#cloud-config
user: $USERNAME
password: $PASSWORD
chpasswd: { expire: False }
ssh_pwauth: True
sudo: ['ALL=(ALL) NOPASSWD:ALL']
groups: sudo
shell: /bin/bash
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - curl
  - htop
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

# SSH-Key injizieren, falls vorhanden
if [ -f "$SSH_KEY_FILE" ]; then
    cat <<EOF >> "$TEMP_DIR/user-data"
ssh_authorized_keys:
  - $(cat "$SSH_KEY_FILE")
EOF
fi

# meta-data
cat <<EOF > "$TEMP_DIR/meta-data"
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

# 5. Cloud-Init Seed ISO bauen (NoCloud Datenquelle)
echo "[*] Erstelle Cloud-Init Seed ISO..."
genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock "$TEMP_DIR/user-data" "$TEMP_DIR/meta-data"
rm -rf "$TEMP_DIR"

# 6. VM über virt-install starten
echo "[*] Definiere und starte VM in libvirt..."
virt-install \
  --name "$VM_NAME" \
  --ram "$RAM_MB" \
  --vcpus "$VCPUS" \
  --os-variant "debian12" \
  --disk "$VM_DISK,device=disk,bus=virtio" \
  --disk "$SEED_ISO,device=cdrom" \
  --network network="$NETWORK",model=virtio \
  --graphics vnc,listen=127.0.0.1,port=-1 \
  --import \
  --noautoconsole

echo "=== Erfolg: $VM_NAME wurde erfolgreich provisioniert! ==="
echo "[i] IP-Adresse ermitteln mit: virsh net-dhcp-leases $NETWORK"
echo "[i] Verbinden via SSH: ssh $USERNAME@<IP>"
