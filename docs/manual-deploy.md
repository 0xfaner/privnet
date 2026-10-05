# Manual deployment

Everything [`privnet.sh deploy`](../privnet.sh) automates can also be done by hand —
useful when you provision the VM yourself or use a provider other than Azure.

## 1. Create the VM (Azure portal)

1. **Virtual machines** -> Create -> Azure virtual machine.
2. Image: **Debian 12** (or Ubuntu 22.04/24.04).
3. Size: `Standard_B2pls_v2` (2 vCPU / 4 GiB, Ampere arm64) is plenty; smaller
   B-series sizes work too.
4. Authentication: SSH public key (recommended); note the username.
5. Inbound ports: allow **SSH (22)**.

### Network security group

Allow these **inbound** rules on the VM's NSG (the Azure-layer firewall,
independent from the in-VM ufw):

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 443 | TCP | VLESS + Reality |
| 8443 | UDP | Hysteria2 |
| 9443 | TCP | AnyTLS |

The defaults are configurable — see `privnet.sh deploy -v/-y/-a` and the variables
at the top of `privnet.sh`.

### Public IP

Use a **static** public IP if the address should survive VM restarts.

## 2. Install mihomo

`privnet.sh` is self-contained and needs only Debian 12 or Ubuntu 22.04/24.04:

```bash
scp privnet.sh azureuser@<public-ip>:~/
ssh azureuser@<public-ip>
sudo bash privnet.sh install
```

A successful manual install prints VLESS and Hysteria2 share links.
Import `/etc/mihomo/client.yaml` for the complete client profile,
including AnyTLS and certificate pins. The local proxy listens on port 7890. Copy it over an authenticated
channel and keep the local copy private.

## 3. Install an existing Azure VM without SSH

`deploy` uses Azure Run Command automatically. On an existing VM, you can
use the same control plane from a machine with an authenticated Azure CLI.
Replace the resource group and VM name before running this example.

```bash
(
  set -e
  wrapper=$(mktemp)
  trap 'rm -f "$wrapper"' EXIT
  {
    cat <<'REMOTE'
#!/usr/bin/env bash
set -eu
installer=$(mktemp /root/privnet.XXXXXX)
trap 'rm -f "$installer"' EXIT
cat > "$installer" <<'PRIVNET_SCRIPT'
REMOTE
    cat privnet.sh
    printf 'PRIVNET_SCRIPT\n'
    printf '%s\n' 'PRIVNET_PRINT_LINKS=0 bash "$installer" install' 'echo PRIVNET_INSTALL_OK'
  } > "$wrapper"
  az vm run-command invoke -g RESOURCE_GROUP -n VM --command-id RunShellScript \
    --scripts "@$wrapper" --query "value[0].message" -o tsv
)
```

Check for `PRIVNET_INSTALL_OK` in the remote stdout, then generate the
subscription with `privnet.sh subscription -g RESOURCE_GROUP VM`.

## Enable IPv6 ingress on an older installation

Binary updates preserve the installed configuration. To enable IPv6
ingress on an older dual-stack VM, back up `/etc/mihomo/config.yaml`, then
change each of the three listener entries from `listen: 0.0.0.0` to
`listen: "::"`. Validate with `sudo mihomo -t -d /etc/mihomo` and restart
mihomo. Verify that Azure and ufw permit inbound IPv6 on the three proxy
ports, then regenerate the subscription with `VM@v6`.

For a custom Azure image, also verify the guest acquired an IPv6 address.
See [Azure DHCPv6 setup](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-ipv6-for-linux).
