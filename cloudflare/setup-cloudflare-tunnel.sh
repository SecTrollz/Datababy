#!/bin/bash
# Run this ON the cloud VM (after azure/setup-azure-frps.sh or
# oracle/setup-oracle-frps.sh has installed frps) to publish frps through a
# Cloudflare Tunnel instead of opening an inbound firewall port for it.
#
# Cloudflare's free tier tunnels make only OUTBOUND connections from this VM
# to Cloudflare's edge, so port 7000 never needs to be reachable from the
# public internet — you can remove that NSG/security-list rule once this is
# working. Requires a domain already onboarded to a (free) Cloudflare account.
#
# Two steps below are interactive by design and cannot be scripted blindly:
# the browser login (picks your Cloudflare account) and the DNS route (picks
# which of your zones/hostnames to use). Everything else is automated.
set -euo pipefail

TUNNEL_NAME="${1:-frp-tunnel}"
HOSTNAME="${2:-}"          # e.g. frp.yourdomain.com — must be a domain in your Cloudflare account
FRPS_LOCAL_PORT="${3:-7000}"

if [ -z "$HOSTNAME" ]; then
    echo "Usage: $0 [tunnel_name=frp-tunnel] <hostname> [frps_local_port=7000]"
    echo "  hostname: e.g. frp.yourdomain.com, a domain already added to your Cloudflare account"
    exit 1
fi

echo "[1/5] Installing cloudflared..."
ARCH=$(dpkg --print-architecture)
wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" -O /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
rm -f /tmp/cloudflared.deb

echo "[2/5] Cloudflare login (opens a URL — open it in a browser and authorize this tunnel)..."
cloudflared tunnel login

command -v jq >/dev/null || { sudo apt-get update -y && sudo apt-get install -y jq; }

echo "[3/5] Creating tunnel '$TUNNEL_NAME'..."
TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r --arg name "$TUNNEL_NAME" '.[] | select(.name == $name) | .id' | head -1)
if [ -z "$TUNNEL_ID" ]; then
    cloudflared tunnel create "$TUNNEL_NAME"
    TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r --arg name "$TUNNEL_NAME" '.[] | select(.name == $name) | .id' | head -1)
fi
CRED_FILE=$(find "$HOME/.cloudflared" -name "${TUNNEL_ID}.json" | head -1)

echo "[4/5] Writing config and routing DNS..."
sudo mkdir -p /etc/cloudflared
sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $HOSTNAME
    service: tcp://127.0.0.1:$FRPS_LOCAL_PORT
  - service: http_status:404
EOF

cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || echo "(DNS route may already exist — continuing)"

echo "[5/5] Installing cloudflared as a systemd service..."
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

echo ""
echo "=================================================="
echo "CLOUDFLARE TUNNEL COMPLETE"
echo "=================================================="
echo "frps is now reachable at $HOSTNAME:443 via Cloudflare, tunneled to"
echo "127.0.0.1:$FRPS_LOCAL_PORT on this VM."
echo ""
echo "You can now remove the public inbound rule for port $FRPS_LOCAL_PORT"
echo "(Azure NSG / OCI security list) since frps no longer needs a public port."
echo ""
echo "On the Termux side, run termux/setup-termux-cloudflared-client.sh with"
echo "this hostname instead of pointing frpc at a raw IP:port."
