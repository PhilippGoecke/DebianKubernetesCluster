#!/bin/bash
set -euo pipefail

# ==============================================================================
# KONFIGURATION
# ==============================================================================
KUBERNETES_VERSION="v1.37" # https://kubernetes.io/releases/
CILIUM_VERSION="v1.20.4" # https://github.com/cilium/cilium/releases
POD_CIDR="10.244.0.0/16"
METALLB_VERSION="v0.16.2" # https://github.com/metallb/metallb/releases
LOCAL_PATH_VERSION="v0.0.37" # https://github.com/rancher/local-path-provisioner
CNI_BIN_DIR="/opt/cni/bin"
CNI_CONF_DIR="/etc/cni/net.d"

# Ermittelt automatisch die primäre IP-Adresse des Servers
MASTER_IP=$(ip -o -4 route get 1.1.1.1 | awk '{print $7}')

echo "=== Starte Kubernetes Komplett-Installation ==="
echo "Node IP: ${MASTER_IP}"
echo "Kubernetes Version: ${KUBERNETES_VERSION}"
echo "Cilium Version: ${CILIUM_VERSION}"
echo "Pod CIDR: ${POD_CIDR}"
echo "MetalLB Version: ${METALLB_VERSION}"
echo "Rancher/local-path Version: ${LOCAL_PATH_VERSION}"
echo "================================================="

# 1. Systemaktualisierung und Basispakete
echo "[1/13] Aktualisiere Systemkomponenten..."
apt update && apt upgrade -y
apt install -y curl gnupg2 apt-transport-https ca-certificates lsb-release

# 2. Swap dauerhaft deaktivieren
echo "[2/13] Deaktiviere Swap..."
swapoff -a
sed -i '/swap/d' /etc/fstab

# 3. Kernel-Module laden & Sysctl für Netzwerk-Routing anpassen
echo "[3/13] Konfiguriere Kernel-Module und Netzwerk..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 4. Containerd (Container Runtime) installieren und konfigurieren
echo "[4/13] Installiere und konfiguriere containerd..."
apt install -y containerd

mkdir -p /etc/containerd
mkdir -p "${CNI_BIN_DIR}" "${CNI_CONF_DIR}"
containerd config default | tee /etc/containerd/config.toml >/dev/null

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
# Containerd und Cilium müssen dieselben CNI-Pfade verwenden.
sed -i \
  -e "s|^\([[:space:]]*bin_dir[[:space:]]*=[[:space:]]*\).*|\1\"${CNI_BIN_DIR}\"|" \
  -e "s|^\([[:space:]]*bin_dirs[[:space:]]*=[[:space:]]*\).*|\1[\"${CNI_BIN_DIR}\"]|" \
  -e "s|^\([[:space:]]*conf_dir[[:space:]]*=[[:space:]]*\).*|\1\"${CNI_CONF_DIR}\"|" \
  /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 5. Kubeadm, Kubelet und Kubectl installieren
echo "[5/13] Installiere Kubernetes Komponenten (${KUBERNETES_VERSION})..."
mkdir -p -m 755 /etc/apt/keyrings

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
chmod 644 /etc/apt/sources.list.d/kubernetes.list

apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 6. Kubernetes Cluster initialisieren (Ohne kube-proxy)
echo "[6/13] Initialisiere Kubernetes Cluster..."
kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --control-plane-endpoint="${MASTER_IP}" \
  --v=5 \
  --skip-phases=addon/kube-proxy

# Kubeconfig für den aktuellen Root/Admin-User einrichten
mkdir -p "$HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

export KUBECONFIG=/etc/kubernetes/admin.conf

# 7. Control-Plane Taints entfernen (Ermöglicht Worker-Funktionalität)
echo "[7/13] Entferne Node-Taints für Single-Node-Betrieb..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true

# 8. Cilium CLI installieren
echo "[8/13] Installiere Cilium CLI..."
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CILIUM_ARCH=amd64

curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CILIUM_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
tar xzvf cilium-linux-${CILIUM_ARCH}.tar.gz -C /usr/local/bin
rm cilium-linux-${CILIUM_ARCH}.tar.gz

# 9. Cilium installieren und CNI-Bereitschaft prüfen
echo "[9/13] Installiere Cilium mit Ingress Controller und Hubble..."
cilium install \
  --version "${CILIUM_VERSION}" \
  --set cni.install=true \
  --set cni.binPath="${CNI_BIN_DIR}" \
  --set cni.confPath="${CNI_CONF_DIR}" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${MASTER_IP}" \
  --set k8sServicePort=6443 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set ingressController.enabled=true \
  --set ingressController.default=true

echo "Warte auf Cilium und die Installation des CNI-Plugins..."
cilium status --wait --wait-duration 5m
if [[ ! -x "${CNI_BIN_DIR}/cilium-cni" ]]; then
  echo "Fehler: ${CNI_BIN_DIR}/cilium-cni fehlt oder ist nicht ausführbar." >&2
  exit 1
fi

# 10. MetalLB erst nach dem CNI installieren, da seine Pods sonst nicht starten können.
echo "[10/13] Installiere MetalLB für LoadBalancer-Support..."
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

echo "Warte auf MetalLB Controller..."
kubectl rollout status deployment -n metallb-system controller --timeout=180s

echo "Warte auf MetalLB Webhook-Endpunkte..."
WEBHOOK_READY=false
for ((attempt=1; attempt<=90; attempt++)); do
  if [[ -n "$(kubectl get endpoints metallb-webhook-service -n metallb-system \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]] && \
    kubectl create --dry-run=server -f - >/dev/null 2>&1 <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  generateName: webhook-readiness-
  namespace: metallb-system
spec:
  addresses:
  - ${MASTER_IP}/32
EOF
  then
    WEBHOOK_READY=true
    break
  fi
  sleep 2
done

if [[ "${WEBHOOK_READY}" != true ]]; then
  echo "Fehler: MetalLB Webhook ist nicht erreichbar oder lehnt den IP-Pool ab." >&2
  kubectl get pods,services,endpoints -n metallb-system >&2 || true
  kubectl logs -n metallb-system deployment/controller --tail=100 >&2 || true
  exit 1
fi

# MetalLB IP-Pool konfigurieren (Verwendet die IP des Host-Systems)
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
  - ${MASTER_IP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - local-pool
EOF

# 11. Persistent Storage installieren (Local Path Provisioner)
echo "[11/13] Installiere Local Path Provisioner für PVC/PV Support..."
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 12. Systemprüfung
echo "[12/13] Bereite Abschlussüberprüfung vor..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl rollout status deployment/local-path-provisioner \
  -n local-path-storage --timeout=120s

# 13. Übersicht ausgeben
echo "===================================================================="
echo "✓ Installation erfolgreich abgeschlossen!"
echo "- StorageClass (Default): local-path"
echo "- Ingress Class: cilium"
echo "- Hubble UI aktivieren: cilium hubble ui"
echo "===================================================================="
kubectl get nodes -o wide
echo "--------------------------------------------------------------------"
kubectl get service -n kube-system cilium-ingress
echo "--------------------------------------------------------------------"
kubectl get pods -n metallb-system
