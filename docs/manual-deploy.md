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

It prints a share link per protocol when done; the [README](../README.md)
documents the generated files and maintenance commands.

## 3. Deploy without SSH (Azure only)

If port 22 is unreachable, embed the script into a run-command wrapper and
execute it through the Azure control plane (`deploy` does this automatically):

```bash
{ printf "cat > /root/privnet.sh <<'EOF'\n"; cat privnet.sh; printf 'EOF\nbash /root/privnet.sh install\n'; } > /tmp/privnet-wrapper.sh
az vm run-command invoke -g <resource-group> -n <vm-name> --command-id RunShellScript \
  --scripts @/tmp/privnet-wrapper.sh --query "value[0].message" -o tsv
rm -f /tmp/privnet-wrapper.sh
```
