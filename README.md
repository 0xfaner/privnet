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
`deploy` also needs an SSH keypair.

```bash
./privnet.sh deploy -g privnet -l japaneast -n privnet-jp   # provision and deploy
./privnet.sh subscription -g privnet privnet-jp             # writes sub.yaml
```

Import `sub.yaml` into any mihomo-core Clash client. On an existing server:

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
Deploying dual-stack also lets `subscription` dial a VM's IPv6 address
instead of its IPv4 one (see `@v6` below).

`subscription` accepts `VM[=LABEL]` to control node naming: the label names
the VM's nodes and selector group (default: the last part of the VM name,
uppercased, so `privnet-jp` becomes `JP`).

By default the nodes dial the VM's IPv4 address. Append `@v6` to a spec
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
(`GEOIP,CN,DIRECT`, `MATCH,PROXY`); including one of those exact lines
replaces that default. Copy
[examples/rules.example.txt](examples/rules.example.txt) to `rules.txt`
(gitignored) and edit it; it is loaded automatically, or pass `-r RULES_FILE`
to use another file.

## What `install` sets up

- Downloads the latest mihomo release for the detected architecture.
- Generates credentials and a self-signed certificate; the server config,
  client snippet and credentials are written to `/etc/mihomo/`.
- Configures ufw for SSH and the proxy ports, enables BBR and starts the
  systemd service.
- Prints one share link per protocol.

## Maintenance

```bash
sudo ./privnet.sh update         # update mihomo; pin with: update v1.19.10
sudo ./privnet.sh uninstall

systemctl status mihomo
journalctl -u mihomo -f
```

## Troubleshooting

1. **Nothing connects** — check both firewalls: the cloud NSG rules and
   `ufw status` on the server.
2. **Hysteria2 fails** — UDP/QUIC is likely throttled; keep `obfs: salamander`
   set on both sides (the default).
3. **SSH times out, VM is running** — port 22 is likely blocked; `deploy` falls
   back to `az vm run-command` automatically.
4. **Reality fails** — its handshake is clock-sensitive; sync client and server
   time and check `443/tcp` in the NSG.
5. **Port already in use** — change the ports at the top of `privnet.sh` and
   update the NSG accordingly.

## Security

- `sub.yaml`, `client.yaml` and `credentials.txt` hold plaintext credentials;
  keep them private and never commit them.
- Restrict the SSH rule to your own IP where possible.

## Docs

- [docs/manual-deploy.md](docs/manual-deploy.md) — manual provisioning and
  installation on an existing server
- [examples/sub.yaml.example](examples/sub.yaml.example) — example subscription
  layout

## License

[MIT](LICENSE)
