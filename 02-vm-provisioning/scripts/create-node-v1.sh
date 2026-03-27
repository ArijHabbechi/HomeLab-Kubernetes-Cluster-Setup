#!/bin/bash

NODE_NAME=$1
BASE_IMG=/var/lib/libvirt/images/k8s/jammy-server-cloudimg-amd64.img
IMG_DIR=/var/lib/libvirt/images/k8s
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)   # make sure this exists

# Create a copy of the base image for this node
sudo qemu-img create -f qcow2 -F qcow2 \
  -b $BASE_IMG $IMG_DIR/${NODE_NAME}.qcow2 40G

# cloud-init: set hostname, user, SSH key, disable swap
cat > /tmp/user-data.yml <<EOF
#cloud-config
hostname: ${NODE_NAME}
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_KEY}
runcmd:
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
EOF

# Create cloud-init ISO
sudo cloud-localds $IMG_DIR/${NODE_NAME}-init.iso /tmp/user-data.yml

# Create the VM
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
