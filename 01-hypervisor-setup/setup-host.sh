sudo apt update && sudo apt upgrade -y

# Install the full KVM/libvirt stack + virt-manager (GUI, optional but handy)
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  bridge-utils \
  virtinst \
  virt-manager \
  cloud-image-utils

# Add yourself to the required groups
sudo usermod -aG libvirt,kvm $USER

# Log out and back in, then verify
virsh list --all

# Create a directory for your VM images
sudo mkdir -p /var/lib/libvirt/images/k8s

# Download the Ubuntu 22.04 cloud image
cd /var/lib/libvirt/images/k8s
sudo wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
