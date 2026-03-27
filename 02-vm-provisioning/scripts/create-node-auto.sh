#!/bin/bash
NODE_NAME=$1
BASE_IMG=/var/lib/libvirt/images/k8s/jammy-server-cloudimg-amd64.img
IMG_DIR=/var/lib/libvirt/images/k8s
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
USERDATA=/tmp/user-data-${NODE_NAME}.yml

cat > $USERDATA <<EOF
#cloud-config
hostname: ${NODE_NAME}

users:
  - name: ubuntu
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_KEY}

write_files:
  - path: /home/ubuntu/.bashrc
    defer: true
    owner: ubuntu:ubuntu
    permissions: '0644'
    content: |
      export PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
      alias ll='ls -lah --color=auto'
      alias k='kubectl'
      source <(kubectl completion bash) 2>/dev/null
      source <(kubeadm completion bash) 2>/dev/null

runcmd:
  # Disable swap
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab

  # Kernel modules — persist across reboots then load now
  - echo -e 'overlay\nbr_netfilter' > /etc/modules-load.d/k8s.conf
  - modprobe overlay
  - modprobe br_netfilter

  # IP forwarding
  - echo -e 'net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1' > /etc/sysctl.d/k8s.conf
  - sysctl --system

  # Install containerd
  - apt-get update -y
  - apt-get install -y containerd
  - chown -R root:root /var/lib/containerd
  - chmod 711 /var/lib/containerd
  - mkdir -p /etc/containerd
  - containerd config default > /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  - systemctl restart containerd
  - systemctl enable containerd

  # Kubernetes apt repo and keyring
  - apt-get install -y apt-transport-https ca-certificates curl
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' > /etc/apt/sources.list.d/kubernetes.list

  # Install Kubernetes binaries
  - apt-get update -y
  - apt-get install -y kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl
EOF

sudo qemu-img create -f qcow2 -F qcow2 \
  -b $BASE_IMG $IMG_DIR/${NODE_NAME}.qcow2 40G

sudo cloud-localds $IMG_DIR/${NODE_NAME}-init.iso $USERDATA

sudo virt-install \
  --name ${NODE_NAME} \
  --ram 4096 \
  --vcpus 2 \
  --disk path=$IMG_DIR/${NODE_NAME}.qcow2,format=qcow2 \
  --disk path=$IMG_DIR/${NODE_NAME}-init.iso,device=cdrom \
  --os-variant ubuntu22.04 \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole
