# Datababy

Outbound-only, cloud-relayed reverse tunnel: an Android/Termux client opens
an outbound connection to your own cloud VM, which then proxies traffic on
its behalf. No inbound ports or public IP are needed on the Android side.

```
Android (Termux)                     Cloud VM (Azure / Oracle Free Tier)
┌─────────────┐   outbound TCP:7000  ┌─────────────┐
│ frpc         │ ───────────────────▶│ frps         │──▶ internet
│ SOCKS5:1080  │◀─────────────────── │ token auth   │
└─────────────┘   persistent tunnel  └─────────────┘
```

Both ends of the tunnel are pluggable:

- **Cloud VM**: Azure (paid, or 12-month free tier) or **Oracle Cloud Always
  Free** (free indefinitely — see `oracle/`).
- **Connectivity**: either a direct IP:port connection, or routed through a
  **Cloudflare Tunnel** (free tier) so the VM needs no open inbound port at
  all — see `cloudflare/`.

## Contents

- `azure/setup-azure-frps.sh` — provisions an Ubuntu VM on Azure, installs
  [frp](https://github.com/fatedier/frp)'s server (`frps`) as a systemd
  service, and generates a random auth token + dashboard password.
- `oracle/setup-oracle-frps.sh` — the same, but provisions an **Oracle Cloud
  Always Free** VM (VCN, subnet, security list, instance) via the OCI CLI
  instead of Azure. No recurring cost.
- `cloudflare/setup-cloudflare-tunnel.sh` — run on either VM above to publish
  frps through a free Cloudflare Tunnel instead of opening a public inbound
  port for it.
- `termux/setup-termux-frpc.sh` — installs frp's client (`frpc`) in Termux,
  writes `frpc.toml`, and keeps it running via `tmux` + a cron watchdog +
  Termux:Boot autostart. Connects directly to the VM's public IP.
- `termux/setup-termux-cloudflared-client.sh` — same, but connects through a
  Cloudflare Tunnel hostname instead of a raw IP (pairs with
  `cloudflare/setup-cloudflare-tunnel.sh`).

## Usage

### Option A: direct IP, Azure or Oracle

1. Provision the server:

   ```bash
   ./azure/setup-azure-frps.sh      # needs `az login` first
   # or
   ./oracle/setup-oracle-frps.sh    # needs `oci setup config` first, and
                                     # COMPARTMENT_ID set in the script
   ```

   This prints the VM's public IP and a generated auth token — save both.

2. In Termux on the Android device:

   ```bash
   ./termux/setup-termux-frpc.sh <server_ip> <auth_token>
   ```

   This starts a local SOCKS5 proxy at `127.0.0.1:1080` tunneled through the
   cloud VM.

3. Point an app or browser's SOCKS5 proxy setting at `127.0.0.1:1080`.

### Option B: no open inbound port, via Cloudflare Tunnel

1. Provision the server as in Option A (Azure or Oracle).
2. On the VM, publish frps through a Cloudflare Tunnel (requires a domain
   already added to a free Cloudflare account):

   ```bash
   ./cloudflare/setup-cloudflare-tunnel.sh frp-tunnel frp.yourdomain.com
   ```

   This step includes an interactive browser login and DNS routing step by
   design — see the comments in the script. Once it's running, remove the
   NSG/security-list rule for port 7000 (and consider rebinding `frps`'s
   `bindAddr` to `127.0.0.1` in `/etc/frp/frps.toml` on the VM) since the
   tunnel no longer needs a public port.

3. In Termux:

   ```bash
   ./termux/setup-termux-cloudflared-client.sh frp.yourdomain.com <auth_token>
   ```

4. Point an app or browser's SOCKS5 proxy setting at `127.0.0.1:1080`.

   If `cloudflared access tcp` refuses the connection, the hostname's TCP
   ingress may need a Cloudflare Access self-hosted application/policy
   (Zero Trust → Access → Applications) in addition to the tunnel route —
   this varies by account and isn't scripted here since it's a one-time,
   account-specific setup step in the Cloudflare dashboard.

## What this does *not* do

These scripts set up the tunnel and a local SOCKS5 endpoint only. Making
*all* system traffic on an unrooted Android device transparently use that
proxy requires a separate `VpnService`-based app (e.g. a tun2socks wrapper)
configured to forward into `127.0.0.1:1080` — not all apps honor a system
SOCKS5 setting, and Termux itself cannot install device-wide routes without
root.

## Notes

- **Cost**: Oracle Cloud's Always Free tier (`oracle/`) and Cloudflare
  Tunnel's free tier (`cloudflare/`) together give a genuinely $0/month
  setup. Azure's free tier covers 12 months; a paid `Standard_B1s` runs
  roughly $4-5/month after that.
- **Security**: keep `frpc.toml`'s auth token secret (the scripts chmod it
  `600`); the frps dashboard is bound to `127.0.0.1` on the VM and reachable
  only via an SSH tunnel, not exposed publicly.
- **Alternatives**: WireGuard is a viable alternative to frp for the same
  outbound-only tunnel pattern, with different tradeoffs (full IP-layer VPN
  vs. a SOCKS5 proxy).
