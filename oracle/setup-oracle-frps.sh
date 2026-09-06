#!/bin/bash
# Provisions an Always Free VM on Oracle Cloud Infrastructure (OCI) and
# installs/configures the FRP server (frps) on it — the OCI equivalent of
# azure/setup-azure-frps.sh.
#
# Requires: OCI CLI installed and configured (`oci setup config`), with
# COMPARTMENT_ID below set to your tenancy or a sub-compartment OCID, and
# `jq` installed locally for parsing CLI output.
#
# Always Free eligible shapes (as of writing): VM.Standard.A1.Flex (up to 4
# OCPUs / 24GB total across all A1 Flex instances) or VM.Standard.E2.1.Micro
# (2 instances, fixed 1 OCPU/1GB each). Defaults below use A1.Flex.
set -euo pipefail

# ============================================================
# CONFIGURATION — EDIT THESE
# ============================================================
COMPARTMENT_ID=""                      # Your tenancy OCID or compartment OCID (required)
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
ADMIN_USER="ubuntu"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
VCN_NAME="frp-proxy-vcn"
SUBNET_NAME="frp-proxy-subnet"
INSTANCE_NAME="frp-proxy-vm"
FRP_VERSION="0.62.0"

if [ -z "$COMPARTMENT_ID" ]; then
    echo "ERROR: Set COMPARTMENT_ID at the top of this script to your tenancy/compartment OCID."
    echo "Find it with: oci iam compartment list --compartment-id-in-subtree true --all"
    echo "(or use your tenancy OCID from: oci iam region list ; oci iam availability-domain list)"
    exit 1
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "ERROR: SSH key not found at $SSH_KEY_PATH"
    echo "Generate one with: ssh-keygen -t rsa -b 4096"
    exit 1
fi

command -v oci >/dev/null || { echo "ERROR: OCI CLI ('oci') not found. Install: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: 'jq' not found. Install it (e.g. apt install jq / brew install jq)."; exit 1; }

FRP_TOKEN=$(openssl rand -base64 32 | tr -d '\n=/+')
DASHBOARD_PASSWORD=$(openssl rand -base64 16 | tr -d '\n=/+')

echo "=================================================="
echo "Oracle Cloud FRPS Setup"
echo "=================================================="
echo "Token (save this): $FRP_TOKEN"
echo "Dashboard Password: $DASHBOARD_PASSWORD"
echo ""

echo "[1/8] Finding availability domain..."
AD=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" --query 'data[0].name' --raw-output)
echo "Availability domain: $AD"

echo "[2/8] Finding latest Ubuntu 22.04 image for $SHAPE..."
IMAGE_ID=$(oci compute image list \
    --compartment-id "$COMPARTMENT_ID" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "22.04" \
    --shape "$SHAPE" \
    --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output)
echo "Image: $IMAGE_ID"

echo "[3/8] Creating VCN..."
VCN_ID=$(oci network vcn create \
    --compartment-id "$COMPARTMENT_ID" \
    --cidr-blocks '["10.0.0.0/16"]' \
    --display-name "$VCN_NAME" \
    --dns-label frpvcn \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)

echo "[4/8] Creating internet gateway + route table..."
IGW_ID=$(oci network internet-gateway create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)

ROUTE_TABLE_ID=$(oci network route-table list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --query 'data[0].id' --raw-output)
oci network route-table update \
    --rt-id "$ROUTE_TABLE_ID" \
    --route-rules '[{"cidrBlock":"0.0.0.0/0","networkEntityId":"'"$IGW_ID"'"}]' \
    --force >/dev/null

echo "[5/8] Opening firewall (security list): SSH 22, FRP 7000..."
SEC_LIST_ID=$(oci network security-list list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --query 'data[0].id' --raw-output)
oci network security-list update --security-list-id "$SEC_LIST_ID" --ingress-security-rules '[
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":7000,"max":7000}}}
]' --force >/dev/null

echo "[6/8] Creating subnet..."
SUBNET_ID=$(oci network subnet create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" \
    --cidr-block "10.0.0.0/24" \
    --display-name "$SUBNET_NAME" \
    --route-table-id "$ROUTE_TABLE_ID" \
    --security-list-ids '["'"$SEC_LIST_ID"'"]' \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)

echo "[7/8] Launching instance ($SHAPE, ${OCPUS} OCPUs, ${MEMORY_GB}GB)..."
SSH_KEY_CONTENT=$(cat "$SSH_KEY_PATH")
INSTANCE_ID=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD" \
    --shape "$SHAPE" \
    --shape-config '{"ocpus":'"$OCPUS"',"memoryInGBs":'"$MEMORY_GB"'}' \
    --display-name "$INSTANCE_NAME" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --metadata '{"ssh_authorized_keys":"'"$SSH_KEY_CONTENT"'"}' \
    --wait-for-state RUNNING \
    --query 'data.id' --raw-output)

PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)
echo "Instance public IP: $PUBLIC_IP"

echo "[8/8] Deploying FRPS via SSH..."
# Wait for SSH to come up
SSH_READY=false
for _ in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$ADMIN_USER@$PUBLIC_IP" true 2>/dev/null; then
        SSH_READY=true
        break
    fi
    sleep 5
done
if [ "$SSH_READY" != true ]; then
    echo "ERROR: SSH did not become reachable at $ADMIN_USER@$PUBLIC_IP after 150s."
    echo "The instance may still be booting — retry manually once it's up:"
    echo "  ssh $ADMIN_USER@$PUBLIC_IP"
    exit 1
fi

# shellcheck disable=SC2087
ssh -o StrictHostKeyChecking=accept-new "$ADMIN_USER@$PUBLIC_IP" bash -s -- "$FRP_VERSION" "$FRP_TOKEN" "$DASHBOARD_PASSWORD" <<'ENDSSH'
set -euo pipefail
FRP_VERSION="$1"
FRP_TOKEN="$2"
DASHBOARD_PASSWORD="$3"

sudo apt update -y
sudo apt install -y wget tar

# Detect arch (A1.Flex = arm64, E2.1.Micro = amd64)
ARCH=$(uname -m)
case "$ARCH" in
    aarch64) FRP_ARCH="arm64" ;;
    x86_64) FRP_ARCH="amd64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

cd /tmp
wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
tar -xzf "frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
cd "frp_${FRP_VERSION}_linux_${FRP_ARCH}"

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

# Oracle images ship with a restrictive iptables ruleset in addition to the
# OCI security list — open the FRP port at the OS firewall level too.
sudo iptables -I INPUT -p tcp --dport 7000 -j ACCEPT
sudo netfilter-persistent save 2>/dev/null || true

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
