# 03 — Kubernetes Cluster Setup
This guide covers the initialization of the Kubernetes control plane, worker node attachment, and the installation of Cilium in a specialized configuration that replaces kube-proxy entirely using eBPF for high-performance networking.

## 📋 Prerequisites

- Successfully provisioned VMs (Master and at least one Worker).
- Connectivity verified between the Host and VM IPs.
- The automated provisioning script [02-vm-provisioning](../02-vm-provisioning) must have finished running.
---

## 1. Verify VMs are ready

```bash
# On the host
for vm in $(virsh list --name); do
  echo "=== $vm ==="
  virsh domifaddr $vm
done

# Inside each VM — wait until cloud-init is done
tail -f /var/log/cloud-init-output.log

# Then confirm tools are installed
kubeadm version && kubectl version --client && containerd --version
```

---

## 2. Initialize the control plane

```bash
ssh ubuntu@<master-ip>

sudo kubeadm init \
  --control-plane-endpoint="<master-ip>:6443" \
  --pod-network-cidr=10.0.0.0/8 \
  --skip-phases=addon/kube-proxy
```

> - `-pod-network-cidr=10.0.0.0/8` — Cilium's default CIDR
> - `-skip-phases=addon/kube-proxy` — **critical for Cilium**: Cilium will replace kube-proxy entirely using eBPF, so you don't want it installed

**Copy the `kubeadm join ...` command printed at the end — you'll need it for workers.**

### Configure kubectl

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Nodes will show NotReady — expected, no CNI installed yet
kubectl get nodes
```

---

## 3. Install Gateway API CRDs

Must be applied **before** Cilium — the Gateway API controller looks for them at startup.

```bash
BASE=https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.1/config/crd

kubectl apply -f $BASE/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f $BASE/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f $BASE/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f $BASE/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f $BASE/experimental/gateway.networking.k8s.io_tlsroutes.yaml

kubectl get crd | grep gateway
```

---

## 4. Install Cilium

```bash
# Install the Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz

# Install Cilium with kube-proxy replacement + Gateway API
cilium install \
  --version v1.18.2 \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=true \
  --set l2announcements.enabled=true

cilium status --wait
```
**gatewayAPI.enabled=true**  
- Ingress` was never designed for complex routing, it exposed a lowest-common-denominator API where anything beyond basic path routing required vendor-specific annotations. Every controller (nginx, traefik, HAProxy) implemented those differently, making configs non-portable and tightly coupled to the controller choice.

- Gateway API fixes this at the API level: it decouples the infrastructure owner (Gateway), the cluster operator (routing rules), and the developer (backend refs) into separate objects with clear ownership boundaries. Routing logic is expressed in standard `HTTPRoute` / `TLSRoute` resources that work identically across any conformant implementation. It is also the direction Kubernetes itself is moving (`Ingress` is effectively frozen, receiving no new features)

> Enabling this flag activates Cilium's built-in Gateway API controller, which runs Envoy as a per-node DaemonSet rather than injecting a sidecar into every pod and achieving the same L7 capability with significantly less overhead.
---

## 5. Join worker nodes

```bash
ssh ubuntu@<worker-ip>

sudo kubeadm join <master-ip>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>

```

***If you lost the join command, regenerate it on the master:***

```kubeadm token create --print-join-command
```
---

## 6. Verify

```bash
# Label the worker
kubectl label node worker1 node-role.kubernetes.io/worker=worker

# All nodes Ready
kubectl get nodes -o wide

# One Cilium pod per node
kubectl -n kube-system get pods -l k8s-app=cilium -o wide

# Full health check
cilium status
```

---

## 7. Cilium L2 Load Balancer

In a standard cloud deployment, when you create a `Service` of type `LoadBalancer`, the cloud provider (AWS, GCP, etc.) automatically provisions an external load balancer and assigns it a public IP. On a bare-metal or local VM setup, nothing does that — services stay stuck at `<pending>` forever.

Cilium solves this with two components:

- **`CiliumLoadBalancerIPPool`** — defines a pool of IPs Cilium is allowed to assign to `LoadBalancer` services. When a service is created, Cilium picks a free IP from this pool and sets it as the `EXTERNAL-IP`.
- **`CiliumL2AnnouncementPolicy`** — once an IP is assigned, the host still doesn't know how to reach it. This policy makes Cilium send **ARP replies** on the specified NIC (`enp1s0`), advertising itself as the owner of that IP at Layer 2. The host then routes traffic to the node, where Cilium forwards it to the right pod.
  
```bash
# Check which IPs are already leased by libvirt
virsh net-dhcp-leases default
```

Apply the pool using a free range in your subnet:

```bash
kubectl apply -f cilium-l2-pool.yaml

kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```
