# k3s Homelab Setup Instructions

This guide will help you set up your homelab Kubernetes cluster using k3s to replace Talos.

## Prerequisites

- Clean Linux installation on all nodes (Ubuntu 22.04/24.04, Debian 11/12, or similar)
- SSH access to all nodes
- At least 2GB RAM per node
- Control plane node: `192.168.8.106`

## Network Configuration

Your cluster will use the same network configuration as before:
- **Control Plane Endpoint**: `192.168.8.106:6443`
- **Pod CIDR**: `10.244.0.0/16` (k3s default: `10.42.0.0/16` - we'll override)
- **Service CIDR**: `10.96.0.0/12` (k3s default: `10.43.0.0/16` - we'll override)

## Step 1: Prepare All Nodes

Run on **all nodes** (control plane + workers):

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install -y curl wget

# Disable swap (if enabled)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Enable IP forwarding
cat <<EOF | sudo tee /etc/sysctl.d/k3s.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sudo sysctl --system
```

## Step 2: Install k3s on Control Plane

Run on the **control plane node** (`192.168.8.106`):

```bash
# Install k3s server with custom network settings
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --cluster-init \
  --tls-san=192.168.8.106 \
  --cluster-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-mode=644" sh -

# Wait for k3s to be ready
sudo systemctl status k3s

# Get the node token for workers
sudo cat /var/lib/rancher/k3s/server/node-token
```

**Save the node token** - you'll need it for worker nodes!

### Option: High Availability Setup (Multiple Control Planes)

If you want HA with multiple control planes, install additional control plane nodes:

```bash
# On additional control plane nodes
curl -sfL https://get.k3s.io | K3S_TOKEN=<NODE_TOKEN> \
  INSTALL_K3S_EXEC="server \
  --server https://192.168.8.106:6443 \
  --tls-san=192.168.8.106 \
  --cluster-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --disable=traefik \
  --disable=servicelb \
  --write-kubeconfig-mode=644" sh -
```

## Step 3: Install k3s on Worker Nodes

Run on **each worker node**:

```bash
# Replace <NODE_TOKEN> with the token from the control plane
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.8.106:6443 \
  K3S_TOKEN=<NODE_TOKEN> sh -
```

## Step 4: Configure kubectl Access

On the **control plane node**:

```bash
# Copy k3s kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/kubeconfig-k3s
sudo chown $USER:$USER ~/kubeconfig-k3s

# Edit the server address
sed -i 's/127.0.0.1/192.168.8.106/g' ~/kubeconfig-k3s
```

Copy this file to your local machine:

```bash
# On your local machine
scp user@192.168.8.106:~/kubeconfig-k3s ./kubeconfig
```

Test the connection:

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes
```

## Step 5: Install Local Path Provisioner

k3s includes Rancher's local-path-provisioner by default, but let's verify:

```bash
kubectl get storageclass
# You should see "local-path (default)"

# Test it
kubectl get pods -n kube-system | grep local-path
```

If not present, install it:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## Step 6: Bootstrap Flux CD

Your Flux configuration is already in the repository. Bootstrap it:

```bash
# Install Flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash

# Verify Flux prerequisites
flux check --pre

# Bootstrap Flux (you'll need GitHub personal access token)
flux bootstrap github \
  --owner=Dinhbaon \
  --repository=homelab \
  --branch=master \
  --path=clusters/homelab \
  --personal

# OR if you want to use your existing SSH key:
# First apply the existing Flux components
kubectl apply -f clusters/homelab/flux-system/gotk-components.yaml
kubectl apply -f clusters/homelab/flux-system/gotk-sync.yaml
kubectl apply -f clusters/homelab/flux-system/kustomization.yaml
```

## Step 7: Configure Git Credentials

If using SSH (your current setup):

```bash
# Create the flux-system namespace if needed
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

# Add your SSH private key
kubectl create secret generic flux-system \
  -n flux-system \
  --from-file=identity=/path/to/your/ssh/private/key \
  --from-literal=known_hosts="$(ssh-keyscan github.com)"
```

## Step 8: Verify Flux Deployment

```bash
# Check Flux components
kubectl get pods -n flux-system

# Check GitRepository sync
flux get sources git

# Check Kustomizations
flux get kustomizations

# Watch reconciliation
flux logs --follow
```

## Step 9: Verify Applications

Your apps should automatically deploy:

```bash
# Check actual-budget
kubectl get all -n actual-budget

# Check PVC
kubectl get pvc -n actual-budget

# Check services
kubectl get svc -n actual-budget
```

## Network & Service Exposure

### Tailscale Integration

Your actual-budget service uses Tailscale LoadBalancer. You'll need to deploy the Tailscale operator:

```bash
# Install Tailscale operator
kubectl apply -f https://github.com/tailscale/tailscale/releases/latest/download/operator.yaml

# Create Tailscale auth secret
kubectl create secret generic tailscale-auth \
  -n tailscale \
  --from-literal=TS_AUTHKEY=<your-tailscale-auth-key>
```

Your service at `clusters/homelab/apps/actual-budget/service.yaml` already has the proper annotations.

## Troubleshooting

### Check k3s logs
```bash
# On any node
sudo journalctl -u k3s -f        # Control plane
sudo journalctl -u k3s-agent -f  # Worker nodes
```

### Check cluster status
```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl cluster-info
```

### Reset a node (if needed)
```bash
# Control plane
sudo /usr/local/bin/k3s-uninstall.sh

# Worker
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

## Differences from Talos

| Feature | Talos | k3s on Linux |
|---------|-------|--------------|
| OS Updates | Immutable, atomic | Traditional apt/dnf |
| Kubernetes Updates | Talos version | k3s version |
| Configuration | YAML machine config | systemd + config files |
| Container Runtime | Included | Included (containerd) |
| CNI | Auto-configured | Auto-configured (flannel) |
| Storage | Needs provisioner | local-path included |
| API Access | talosctl + kubectl | kubectl only |
| Certificates | Auto-managed | Auto-managed |

## Key Benefits of k3s

- Single binary installation
- Low resource footprint
- Batteries included (CNI, storage, metrics)
- Easy upgrades: `curl -sfL https://get.k3s.io | sh -`
- Production-ready (CNCF certified)

## Next Steps

1. Complete the setup above
2. Update your `kubeconfig` file in this repo with the new cluster credentials
3. Monitor Flux deployment: `flux logs --follow`
4. Verify all apps are running: `kubectl get pods -A`
5. Set up Tailscale operator for service exposure

Your GitOps setup should handle the rest automatically!
