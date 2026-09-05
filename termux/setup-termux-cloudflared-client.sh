#!/data/data/com.termux/files/usr/bin/bash
# Alternative to pointing frpc directly at a public IP: runs `cloudflared
# access tcp` in Termux to reach frps through a Cloudflare Tunnel (set up by
# cloudflare/setup-cloudflare-tunnel.sh on the VM), then points frpc at that
# local forwarded port instead. Use this when the VM has no open inbound
# port for FRP.
#
# Usage:
#   ./setup-termux-cloudflared-client.sh <tunnel_hostname> <auth_token> [local_forward_port=7000] [local_socks_port=1080]
set -euo pipefail

TUNNEL_HOSTNAME="${1:-}"
AUTH_TOKEN="${2:-}"
LOCAL_FORWARD_PORT="${3:-7000}"
LOCAL_SOCKS_PORT="${4:-1080}"
FRP_VERSION="0.62.0"

if [ -z "$TUNNEL_HOSTNAME" ] || [ -z "$AUTH_TOKEN" ]; then
    echo "Usage: $0 <tunnel_hostname> <auth_token> [local_forward_port=7000] [local_socks_port=1080]"
    exit 1
fi

echo "[1/5] Installing packages..."
pkg update -y
pkg install -y wget tar openssl-tool tmux cronie termux-services cloudflared

ARCH=$(uname -m)
case "$ARCH" in
    aarch64) FRP_ARCH="arm64" ;;
    armv7l|armv8l) FRP_ARCH="arm" ;;
    x86_64) FRP_ARCH="amd64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

FRP_DIR="$HOME/frp"
mkdir -p "$FRP_DIR" "$HOME/.termux/boot"
cd "$FRP_DIR"

echo "[2/5] Downloading frpc ($FRP_ARCH)..."
ARCHIVE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${ARCHIVE}"
tar -xzf "$ARCHIVE" --strip-components=1 "frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc"
rm -f "$ARCHIVE"
chmod +x frpc

echo "[3/5] Writing frpc.toml (points at the local cloudflared forward, not a public IP)..."
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "127.0.0.1"
serverPort = $LOCAL_FORWARD_PORT

[auth]
method = "token"
token = "$AUTH_TOKEN"

[[proxies]]
name = "socks5"
type = "tcp"
localIP = "127.0.0.1"
localPort = $LOCAL_SOCKS_PORT
remotePort = $LOCAL_SOCKS_PORT
EOF
chmod 600 "$FRP_DIR/frpc.toml"

echo "[4/5] Setting up watchdog + autostart for cloudflared + frpc..."
cat > "$FRP_DIR/watchdog.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
if ! tmux has-session -t cfd 2>/dev/null; then
    tmux new-session -d -s cfd "cloudflared access tcp --hostname $TUNNEL_HOSTNAME --url 127.0.0.1:$LOCAL_FORWARD_PORT"
    sleep 2
fi
if ! tmux has-session -t frpc 2>/dev/null; then
    cd "$FRP_DIR"
    tmux new-session -d -s frpc './frpc -c frpc.toml'
fi
EOF
chmod +x "$FRP_DIR/watchdog.sh"

cat > "$HOME/.termux/boot/start-frpc.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
"$FRP_DIR/watchdog.sh"
EOF
chmod +x "$HOME/.termux/boot/start-frpc.sh"

sv-enable crond >/dev/null 2>&1 || true
( crontab -l 2>/dev/null | grep -v 'frpc-watchdog' || true; \
  echo "*/5 * * * * $FRP_DIR/watchdog.sh # frpc-watchdog" ) | crontab -

echo "[5/5] Starting cloudflared + frpc..."
tmux kill-session -t cfd 2>/dev/null || true
tmux kill-session -t frpc 2>/dev/null || true
tmux new-session -d -s cfd "cloudflared access tcp --hostname $TUNNEL_HOSTNAME --url 127.0.0.1:$LOCAL_FORWARD_PORT"
sleep 2
tmux new-session -d -s frpc "cd $FRP_DIR && ./frpc -c frpc.toml"

echo ""
echo "=================================================="
echo "Running: cloudflared (tmux 'cfd') -> frpc (tmux 'frpc')"
echo "SOCKS5 proxy: 127.0.0.1:$LOCAL_SOCKS_PORT"
echo "=================================================="
