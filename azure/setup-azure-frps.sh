#!/bin/bash
# Provisions an Azure VM and installs/configures the FRP server (frps) on it.
# Requires: Azure CLI installed and logged in (az login).
set -euo pipefail

# ============================================================
# CONFIGURATION — EDIT THESE
# ============================================================
RESOURCE_GROUP="frp-proxy-rg"
VM_NAME="frp-proxy-vm"
LOCATION="eastus"           # Change to your preferred region
VM_SIZE="Standard_B1s"      # Smallest/cheapest
ADMIN_USER="azureuser"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"  # Your public SSH key
FRP_VERSION="0.62.0"

# ============================================================
# GENERATE RANDOM SECURE TOKEN
# ============================================================
FRP_TOKEN=$(openssl rand -base64 32 | tr -d '\n=/+' )
DASHBOARD_PASSWORD=$(openssl rand -base64 16 | tr -d '\n=/+')

echo "=================================================="
echo "Azure FRPS Setup"
echo "=================================================="
echo "Token (save this): $FRP_TOKEN"
echo "Dashboard Password: $DASHBOARD_PASSWORD"
echo ""

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "ERROR: SSH key not found at $SSH_KEY_PATH"
    echo "Generate one with: ssh-keygen -t rsa -b 4096"
    exit 1
fi

# ============================================================
# CREATE RESOURCE GROUP AND VM
# ============================================================
echo "[1/4] Creating resource group..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null

echo "[2/4] Creating VM..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --image "Ubuntu2204" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --ssh-key-values "$SSH_KEY_PATH" \
    --public-ip-sku Standard >/dev/null

PUBLIC_IP=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --show-details --query publicIps -o tsv)
echo "VM Public IP: $PUBLIC_IP"

# ============================================================
# OPEN FIREWALL PORTS
# ============================================================
echo "[3/4] Opening firewall ports..."
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --port 7000 --priority 1000 >/dev/null
# The dashboard (port 7500) is bound to 127.0.0.1 on the VM below, so it is
# intentionally NOT opened here. Reach it over an SSH tunnel instead (see the
# final instructions this script prints).

# ============================================================
# DEPLOY FRPS VIA SSH
# ============================================================
echo "[4/4] Deploying FRPS via SSH..."

# shellcheck disable=SC2087
ssh -o StrictHostKeyChecking=accept-new "$ADMIN_USER@$PUBLIC_IP" bash -s -- "$FRP_VERSION" "$FRP_TOKEN" "$DASHBOARD_PASSWORD" <<'ENDSSH'
set -euo pipefail
FRP_VERSION="$1"
FRP_TOKEN="$2"
DASHBOARD_PASSWORD="$3"

sudo apt update -y
sudo apt install -y wget tar

cd /tmp
wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
tar -xzf "frp_${FRP_VERSION}_linux_amd64.tar.gz"
cd "frp_${FRP_VERSION}_linux_amd64"

sudo cp frps /usr/local/bin/
sudo chmod +x /usr/local/bin/frps

sudo mkdir -p /etc/frp

sudo tee /etc/frp/frps.toml > /dev/null <<EOF
bindAddr = "0.0.0.0"
bindPort = 7000

[auth]
method = "token"
token = "$FRP_TOKEN"

[webServer]
addr = "127.0.0.1"
port = 7500
user = "admin"
password = "$DASHBOARD_PASSWORD"
EOF

sudo tee /etc/systemd/system/frps.service > /dev/null <<'EOF'
[Unit]
Description = FRP Server
After = network.target syslog.target
Wants = network.target

[Service]
Type = simple
ExecStart = /usr/local/bin/frps -c /etc/frp/frps.toml
Restart = always
RestartSec = 10

[Install]
WantedBy = multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable frps
sudo systemctl restart frps

echo "FRPS installed and running."
ENDSSH

echo ""
echo "=================================================="
echo "SETUP COMPLETE"
echo "=================================================="
echo "Server IP:    $PUBLIC_IP"
echo "FRP Token:    $FRP_TOKEN"
echo "Dashboard:    bound to 127.0.0.1:7500 on the VM (admin / $DASHBOARD_PASSWORD)."
echo "              Reach it via: ssh -L 7500:127.0.0.1:7500 $ADMIN_USER@$PUBLIC_IP"
echo ""
echo "Copy the server IP and token into termux/setup-termux-frpc.sh on your device."
