#!/data/data/com.termux/files/usr/bin/bash
# Installs and configures the FRP client (frpc) in Termux, pointed at an
# Azure/VPS host running frps (see azure/setup-azure-frps.sh).
#
# Usage:
#   ./setup-termux-frpc.sh <server_ip> <auth_token> [server_port=7000] [local_socks_port=1080]
set -euo pipefail

SERVER_ADDR="${1:-}"
AUTH_TOKEN="${2:-}"
SERVER_PORT="${3:-7000}"
LOCAL_SOCKS_PORT="${4:-1080}"
FRP_VERSION="0.62.0"

if [ -z "$SERVER_ADDR" ] || [ -z "$AUTH_TOKEN" ]; then
    echo "Usage: $0 <server_ip> <auth_token> [server_port=7000] [local_socks_port=1080]"
    exit 1
fi

echo "[1/5] Installing packages..."
pkg update -y
pkg install -y wget tar openssl-tool tmux cronie termux-services

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

echo "[3/5] Writing frpc.toml..."
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER_ADDR"
serverPort = $SERVER_PORT

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

echo "[4/5] Setting up watchdog + autostart..."
cat > "$FRP_DIR/watchdog.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
if ! tmux has-session -t frpc 2>/dev/null; then
    cd "$FRP_DIR"
    tmux new-session -d -s frpc './frpc -c frpc.toml'
fi
EOF
chmod +x "$FRP_DIR/watchdog.sh"

# termux-boot: starts frpc when the device boots (requires the Termux:Boot
# app to be installed from the same source as Termux itself).
cat > "$HOME/.termux/boot/start-frpc.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
"$FRP_DIR/watchdog.sh"
EOF
chmod +x "$HOME/.termux/boot/start-frpc.sh"

# cron watchdog: relaunches frpc every 5 minutes if the tmux session died
# (network change, OOM kill, etc).
sv-enable crond >/dev/null 2>&1 || true
( crontab -l 2>/dev/null | grep -v 'frpc-watchdog' || true; \
  echo "*/5 * * * * $FRP_DIR/watchdog.sh # frpc-watchdog" ) | crontab -

echo "[5/5] Starting frpc..."
tmux kill-session -t frpc 2>/dev/null || true
tmux new-session -d -s frpc "cd $FRP_DIR && ./frpc -c frpc.toml"

echo ""
echo "=================================================="
echo "frpc is running (tmux session 'frpc')."
echo "SOCKS5 proxy: 127.0.0.1:$LOCAL_SOCKS_PORT"
echo "=================================================="
echo "Point apps/browsers that support a SOCKS5 proxy at 127.0.0.1:$LOCAL_SOCKS_PORT."
echo ""
echo "Termux alone cannot transparently route ALL system traffic through this"
echo "proxy without root (iptables/redsocks) or a separate VpnService-based"
echo "app (e.g. a tun2socks wrapper) pointed at 127.0.0.1:$LOCAL_SOCKS_PORT — this"
echo "script only sets up the tunnel + local SOCKS5 endpoint, not that wrapper."
