# Datababy

Outbound-only, cloud-relayed reverse tunnel: an Android/Termux client opens
an outbound connection to your own cloud VM, which then proxies traffic on
its behalf. No inbound ports or public IP are needed on the Android side.

```
Android (Termux)                     Cloud VM (Azure/any VPS)
┌─────────────┐   outbound TCP:7000  ┌─────────────┐
│ frpc         │ ───────────────────▶│ frps         │──▶ internet
│ SOCKS5:1080  │◀─────────────────── │ token auth   │
└─────────────┘   persistent tunnel  └─────────────┘
```

## Contents

- `azure/setup-azure-frps.sh` — provisions an Ubuntu VM on Azure, installs
  [frp](https://github.com/fatedier/frp)'s server (`frps`) as a systemd
  service, and generates a random auth token + dashboard password.
- `termux/setup-termux-frpc.sh` — installs frp's client (`frpc`) in Termux,
  writes `frpc.toml`, and keeps it running via `tmux` + a cron watchdog +
  Termux:Boot autostart.

## Usage

1. On a machine with the Azure CLI installed and `az login` already run:

   ```bash
   ./azure/setup-azure-frps.sh
   ```

   This prints the VM's public IP and a generated auth token — save both.

2. In Termux on the Android device:

   ```bash
   ./termux/setup-termux-frpc.sh <server_ip> <auth_token>
   ```

   This starts a local SOCKS5 proxy at `127.0.0.1:1080` tunneled through the
   cloud VM.

3. Point an app or browser's SOCKS5 proxy setting at `127.0.0.1:1080`.

## What this does *not* do

These scripts set up the tunnel and a local SOCKS5 endpoint only. Making
*all* system traffic on an unrooted Android device transparently use that
proxy requires a separate `VpnService`-based app (e.g. a tun2socks wrapper)
configured to forward into `127.0.0.1:1080` — not all apps honor a system
SOCKS5 setting, and Termux itself cannot install device-wide routes without
root.

## Notes

- **Cost**: an always-on VM is not free. Azure's free tier (12 months, B1s)
  or a one-time-cost/always-free VPS (e.g. Oracle Cloud's free tier) avoids
  recurring charges; a paid `Standard_B1s` runs roughly $4-5/month.
- **Security**: keep `frpc.toml`'s auth token secret (the script chmods it
  `600`); the frps dashboard is bound to `127.0.0.1` on the VM and reachable
  only via an SSH tunnel, not exposed publicly.
- **Alternatives**: [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
  (no VPS to manage) and WireGuard are viable alternatives to frp for the
  same outbound-only tunnel pattern, with different tradeoffs — see the
  comparison in project history/commit messages for details.
