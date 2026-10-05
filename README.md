# privnet

Self-hosted proxy server built on
[mihomo](https://github.com/MetaCubeX/mihomo) (Clash.Meta). One instance
serves three protocols:

| Protocol | Port | Transport |
|----------|------|-----------|
| VLESS + Reality | `443/tcp` | TCP |
| Hysteria2 | `8443/udp` | QUIC |
| AnyTLS | `9443/tcp` | TCP+TLS |

Runs on Debian 12 and Ubuntu 22.04/24.04 (amd64/arm64). The `deploy`
command provisions an Azure VM and runs `install` on it.

## Quick start

Both `deploy` and `subscription` need a logged-in
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
`deploy` installs through Azure Run Command and needs an SSH public key
to provision the VM's administrator account. Use `-k` to pass a public key.

```bash
./privnet.sh deploy -g privnet -l japaneast -n privnet-jp   # provision and deploy
./privnet.sh subscription -g privnet privnet-jp             # writes sub.yaml
```

Import `sub.yaml` into a mihomo-based client that supports the selected
protocols and TLS certificate pinning. On an existing server:

```bash
sudo ./privnet.sh install
```

## Commands

| Command | Runs on | Purpose |
|---------|---------|---------|
| `deploy` | your machine | Provision an Azure VM and deploy the proxy on it |
| `install` | the server, as root | Install and configure mihomo |
| `update [VERSION]` | the server, as root | Update mihomo to the latest release or a pinned version |
| `uninstall` | the server, as root | Remove mihomo, its config, sysctl settings and firewall rules |
| `subscription` | your machine | Build a Clash subscription from deployed VMs |

Run `./privnet.sh <command> -h` for options. Ports and other settings are
variables at the top of `privnet.sh`.

`deploy` supports dual-stack (IPv4 + IPv6) provisioning for IPv6-only
destinations: pass `-p <v6-prefix>` with a GUA block you control, sized /48,
/52 or /56 (e.g. `2a11:6f3c:9d2e::/48`). The block is used only inside the
VNet; outbound IPv6 traffic exits through the VM's static public IPv6.
Deploying dual-stack also lets `subscription` dial the public IPv6 address
attached to that VM (see `@v6` below). For an older installation, see
[listener migration](docs/manual-deploy.md#enable-ipv6-ingress-on-an-older-installation).

`subscription` accepts `VM[=LABEL]` to control node naming: the label names
the VM's nodes and selector group (default: the last part of the VM name,
uppercased, so `privnet-jp` becomes `JP`). Use letters, digits, underscores,
periods or hyphens, starting with a letter or digit. Labels and generated
node names must be unique across the subscription.

By default the nodes dial the public IPv4 address attached to the VM. Append `@v6` to a spec
(`privnet-jp=JP@v6`) to dial its static public IPv6 address instead, or pass
`-6`/`--ipv6` to make that the default for every spec (`@v4` restores the
default for one VM). The subscription then sets `ipv6: true`, which mihomo
requires in order to dial a literal IPv6 address. Measure first, because an
ISP's route can be better over IPv6 for one region and worse for another.

`-p`/`--protocols` limits the emitted nodes to a subset of
`vless,hy2,anytls` (default: all three; `all` is a shorthand). Use it to
leave out protocols a client mishandles, so its selector never lands on a
dead node — e.g. `-p vless,anytls` for a client whose Hysteria2 is broken:

```bash
./privnet.sh subscription -p vless,anytls privnet-jp@v6 privnet-sg
```

Custom Clash rules are inserted before the built-in defaults
(`GEOIP,CN,DIRECT`, `MATCH,PROXY`). An exact `GEOIP,CN,DIRECT` entry
replaces that default. A custom `MATCH` rule replaces the default catch-all. Copy
[examples/rules.example.txt](examples/rules.example.txt) to `rules.txt`
(gitignored) and edit it; it is loaded automatically, or pass `-r RULES_FILE`
to use another file.

## What `install` sets up

- Downloads the selected mihomo release and verifies its SHA-256 digest
  against the GitHub release metadata before execution.
- Creates a private configuration directory under `/etc/mihomo/` and
  generates credentials and a self-signed certificate. Hysteria2 and
  AnyTLS client profiles pin that certificate.
- Validates the generated configuration, starts the systemd service and
  checks that its process owns all three listener sockets. It also opens
  the proxy and SSH ports in ufw and attempts to enable BBR.
- Prints VLESS and Hysteria2 share links after a successful manual
  installation. Use `/etc/mihomo/client.yaml` for AnyTLS. Set
  `PRIVNET_PRINT_LINKS=0` to suppress links. Azure deployments suppress
  them automatically.

## Maintenance

```bash
sudo ./privnet.sh update         # update mihomo; pin with: update v1.19.10
sudo ./privnet.sh uninstall

systemctl status mihomo
journalctl -u mihomo -f
```

Updates validate the candidate against the installed configuration before
replacing the binary. If the new service fails its startup check, privnet
restores the previous binary and attempts to restart it. The updater installs
missing dependencies for older installations. Pinned releases require a
SHA-256 digest in the release metadata.

Uninstall removes proxy ufw rules recorded by this installer and keeps SSH
rules. If a deletion fails, fix ufw and retry uninstall. For older installs, review obsolete proxy rules in ufw after uninstalling.
Uninstall removes the BBR configuration file. Runtime sysctl values may
persist until reboot.

## Troubleshooting

1. **Nothing connects** — check both firewalls: the cloud NSG rules and
   `ufw status` on the server.
2. **Hysteria2 fails** — UDP/QUIC is likely throttled; keep `obfs: salamander`
   set on both sides (the default).
3. **Azure install fails** — check the returned Run Command output and
   the VM agent. A failed deployment can leave billable resources. Inspect
   resources for that VM before retrying, especially in a shared group.
4. **Reality fails** — its handshake is clock-sensitive; sync client and server
   time and check `443/tcp` in the NSG.
5. **Port already in use** — change the ports at the top of `privnet.sh` and
   update the NSG accordingly.

## Security

- `sub.yaml`, `client.yaml` and `credentials.txt` hold plaintext credentials;
  keep them private and never commit them. Subscription generation reads
  credentials through Azure Run Command. Keep that output private too.
- The proxy rejects loopback, private and link-local destination ranges and
  the Azure platform IP. Azure dual-stack deployment also rejects the
  configured IPv6 subnet.
- Restrict the SSH rule to your own IP where possible.
- Rebuild and re-import subscriptions after changing the server certificate.
  Rebuild existing subscriptions to add pins to profiles from older installs.
  If importing a Hysteria2 URI, use a client that honors `pinSHA256`.

## Docs

- [docs/manual-deploy.md](docs/manual-deploy.md) — manual provisioning and
  installation on an existing server
- [examples/sub.yaml.example](examples/sub.yaml.example) — example subscription
  layout

## License

[MIT](LICENSE)
