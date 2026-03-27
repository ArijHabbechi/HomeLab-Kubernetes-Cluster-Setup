# 02 — VM Provisioning

This section covers the provisioning of KVM virtual machines into ready-to-join Kubernetes nodes — with all prerequisites handled before the cluster is initialized: swap disabled, kernel modules persisted, containerd configured with the correct cgroup driver, and Kubernetes binaries pinned to prevent version skew.

Before running either script, make sure you have an SSH key pair generated — the public key gets injected into the VMs via cloud-init and is the only way to access them after boot:
```bash
ssh-keygen -t rsa -b 4096
```
## Option A — Automated (recommended)

The `create-node-auto.sh` script does everything in one shot: creates the disk, generates a cloud-init ISO, and boots the VM. Cloud-init then handles the full node configuration automatically (swap, kernel modules, containerd, kubeadm/kubelet/kubectl).
```bash
bash create-vm.sh master
bash create-vm.sh worker1
```

> ⚠️ Cloud-init runs in the background after boot. Wait 3–5 minutes before proceeding.  
> Monitor progress: `ssh ubuntu@<vm-ip> 'tail -f /var/log/cloud-init-output.log'`

---

## Option B — Manual

Use `create-vm-v1.sh <node-name>` to create a plain VM.
Once the VMs are up, retrieve their IPs with:
```bash
virsh domifaddr <node-name>

# or for all VMs at once
for vm in $(virsh list --name); do
  echo "=== $vm ==="
  virsh domifaddr $vm
done
```
Then SSH in and run the following manually on **every node**:
```bash
ssh ubuntu@<vm-ip>

# Disable swap — kubeadm requires this
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Enable IP forwarding
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Install containerd
sudo apt update
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Add the Kubernetes apt repository
sudo apt install -y apt-transport-https ca-certificates curl
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install Kubernetes binaries
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

> `apt-mark hold` pins the versions to prevent unintended upgrades that could break cluster compatibility.

Repeat on every node before moving to `03-k8s-cluster`.

---
| Step | Why |
|---|---|
| Disable swap | kubeadm hard-requires swap to be off |
| `overlay` + `br_netfilter` | Required by containerd and Kubernetes networking |
| IP forwarding + bridge iptables | Allows pods to communicate across nodes |
| `SystemdCgroup = true` | Aligns containerd's cgroup driver with kubelet's expected driver |
| `apt-mark hold` | Prevents accidental version skew between nodes |
