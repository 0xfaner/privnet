#!/usr/bin/env bash
#
# privnet.sh - Self-hosted mihomo (Clash.Meta) proxy in one script.
#
# Commands:
#   deploy        Provision an Azure VM and deploy the proxy on it
#   install       Install and configure mihomo on this machine (run as root)
#   update        Update mihomo on this machine (run as root)
#   uninstall     Remove mihomo from this machine (run as root)
#   subscription  Generate a Clash subscription from deployed VMs
#   help          Show usage
#
# An installed server serves three protocols at once:
#   VLESS + Reality (TCP), Hysteria2 (UDP/QUIC), AnyTLS (TCP)
#
# Server support: Debian 12 (primary), Ubuntu 22.04 / 24.04 (amd64/arm64).
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="${SELF_DIR}/$(basename "${BASH_SOURCE[0]}")"

TAG="privnet"

################################################################################
# Shared settings
################################################################################

# Server file layout (install / update / uninstall)
MIHOMO_BIN="/usr/local/bin/mihomo"
CONF_DIR="/etc/mihomo"
SERVICE="mihomo"
SYSCTL_FILE="/etc/sysctl.d/99-privnet-bbr.conf"

# Proxy ports; deploy passes -v/-y/-a to the server through these overrides.
VLESS_PORT="${PRIVNET_VLESS_PORT:-443}"       # VLESS + Reality (TCP)
HY2_PORT="${PRIVNET_HY2_PORT:-8443}"          # Hysteria2 (UDP)
ANYTLS_PORT="${PRIVNET_ANYTLS_PORT:-9443}"    # AnyTLS (TCP)

# SSH port allowed through the firewall / NSG
SSH_PORT="${PRIVNET_SSH_PORT:-22}"

################################################################################
# Shared helpers
################################################################################

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$TAG" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$TAG" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$TAG" "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root: sudo bash ${SELF_PATH} ${TAG}"
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
  else
    die "Unable to detect OS (missing /etc/os-release)"
  fi
  case "$OS_ID" in
    debian) log "Detected Debian ${OS_VERSION_ID}" ;;
    ubuntu) log "Detected Ubuntu ${OS_VERSION_ID}" ;;
    *) die "Unsupported OS: ${OS_ID}. Only Debian / Ubuntu are supported." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m) (only amd64 / arm64)" ;;
  esac
}

# True when a release JSON body lists an asset with exactly this name.
# (Plain case matching: piping into 'grep -q' would SIGPIPE the writer on
# large JSON under pipefail.)
release_has_asset() {
  case "$1" in
    *"\"name\": \"$2\""*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the download URL of a mihomo release asset for $ARCH.
# $1: "latest" or a release tag, e.g. v1.19.10
mihomo_asset_url() {
  local ver="$1" release_json candidate
  # Resolve via the API for pinned tags too: asset names vary between builds
  # (-v1-, -compatible-), so the release's asset list is authoritative.
  if [ "$ver" = "latest" ]; then
    release_json=$(curl -fsSL "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest") \
      || die "Cannot reach GitHub API, check outbound network"
    ver=$(printf '%s' "$release_json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    [ -n "$ver" ] || die "Cannot parse latest mihomo version"
  else
    release_json=$(curl -fsSL "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/${ver}") \
      || die "Cannot find mihomo release ${ver} on GitHub"
  fi
  # Try in order: baseline build, v1 build, most-compatible build.
  for candidate in \
    "mihomo-linux-${ARCH}-${ver}.gz" \
    "mihomo-linux-${ARCH}-v1-${ver}.gz" \
    "mihomo-linux-${ARCH}-compatible-${ver}.gz"; do
    if release_has_asset "$release_json" "$candidate"; then
      printf 'https://github.com/MetaCubeX/mihomo/releases/download/%s/%s\n' "$ver" "$candidate"
      return 0
    fi
  done
  die "No mihomo binary found for architecture ${ARCH} in release ${ver}"
}

# Download a mihomo release and install it at $2, verifying it executes.
# $1: "latest" or a release tag; $2: destination path
download_mihomo() {
  local ver="$1" dest="$2" url tmp_gz
  url=$(mihomo_asset_url "$ver")
  log "Downloading mihomo from ${url}"
  tmp_gz=$(mktemp /tmp/mihomo.XXXXXX)
  curl -fsSL --retry 3 -o "$tmp_gz" "$url" || die "Failed to download mihomo"
  gzip -dc "$tmp_gz" > "$dest" || die "Failed to extract mihomo"
  rm -f "$tmp_gz"
  chmod 755 "$dest"
  "$dest" -v >/dev/null 2>&1 || die "Downloaded mihomo binary cannot execute"
}

# Read the [stdout] part of a shell command run on a VM via az run-command.
# $4, if given, is a file that receives az's stderr. Returns az's status.
run_command_stdout() {
  local rg="$1" vm="$2" script="$3" err="${4:-/dev/null}" msg
  msg=$(az vm run-command invoke -g "$rg" -n "$vm" --command-id RunShellScript \
        --scripts "$script" --query "value[0].message" -o tsv 2>"$err") || return 1
  printf '%s\n' "$msg" | awk '/^\[stdout\]/{f=1; next} /^\[stderr\]/{f=0} f'
}

# Die unless mihomo is active on the VM. az run-command can exit 0 even when
# the remote script failed, so the service state must be checked explicitly.
verify_service_active() {
  local rg="$1" vm="$2" state
  state=$(run_command_stdout "$rg" "$vm" "systemctl is-active ${SERVICE} 2>/dev/null || true") || state=""
  [ "$state" = "active" ] || {
    warn "mihomo is not active on ${vm} (state: ${state:-unknown})"
    warn "Inspect: az vm run-command invoke -g ${rg} -n ${vm} --command-id RunShellScript --scripts 'journalctl -u ${SERVICE} -n 50'"
    warn "To start over: az group delete -n ${rg} --yes"
    die "Deployment finished but mihomo is not running on ${vm}"
  }
  log "mihomo is active on ${vm}"
}

################################################################################
# install
################################################################################

REALITY_SERVER_NAME="www.microsoft.com"
REALITY_DEST="${REALITY_SERVER_NAME}:443"
CERT_CN="mihomo.local"
SERVER_IP=""                 # empty: auto-detect (Azure metadata, then ipify)
MIHOMO_VERSION="${PRIVNET_MIHOMO_VERSION:-latest}"   # "latest" or a pinned release tag, e.g. v1.19.10
VLESS_USER="vless"           # usernames are labels only, no security impact
HY2_USER="hy2"
ANYTLS_USER="anytls"

usage_install() {
  cat <<EOF
Usage: privnet.sh install

Installs and configures mihomo on this machine (run as root with sudo).

Settings live at the top of this script; each can be overridden via the
environment (PRIVNET_VLESS_PORT, PRIVNET_HY2_PORT, PRIVNET_ANYTLS_PORT,
PRIVNET_SSH_PORT, PRIVNET_MIHOMO_VERSION):
  ports:    VLESS ${VLESS_PORT}/tcp, Hysteria2 ${HY2_PORT}/udp, AnyTLS ${ANYTLS_PORT}/tcp
  firewall: SSH ${SSH_PORT}/tcp
EOF
}

install_deps() {
  log "Installing dependencies (curl gzip openssl ufw ca-certificates)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl gzip openssl ufw ca-certificates >/dev/null
}

gen_credentials() {
  log "Generating credentials..."
  VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
  HY2_PASSWORD=$(openssl rand -hex 16)
  HY2_OBFS_PASSWORD=$(openssl rand -hex 16)
  ANYTLS_PASSWORD=$(openssl rand -hex 16)
  SHORT_ID=$(openssl rand -hex 8)

  # Reality keypair is generated by mihomo
  local kp
  kp=$("$MIHOMO_BIN" generate reality-keypair) || die "Failed to generate Reality keypair"
  REALITY_PRIVKEY=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey: *//p')
  REALITY_PUBKEY=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey: *//p')
  [ -n "$REALITY_PRIVKEY" ] && [ -n "$REALITY_PUBKEY" ] || die "Failed to parse Reality keypair"
}

gen_cert() {
  log "Generating self-signed cert (CN=${CERT_CN}, valid 10 years)..."
  mkdir -p "$CONF_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CONF_DIR/server.key" \
    -out "$CONF_DIR/server.crt" \
    -days 3650 \
    -subj "/CN=${CERT_CN}" >/dev/null 2>&1 || die "Failed to generate self-signed cert"
  chmod 600 "$CONF_DIR/server.key"
  chmod 644 "$CONF_DIR/server.crt"
}

detect_server_ip() {
  if [ -n "$SERVER_IP" ]; then
    printf '%s\n' "$SERVER_IP"
    return 0
  fi
  local ip=""
  # Try the Azure Instance Metadata service first, then an external service
  ip=$(curl -fsS -m 5 -H "Metadata:true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" 2>/dev/null || true)
  if [ -z "$ip" ]; then
    ip=$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true)
  fi
  [ -n "$ip" ] || die "Cannot auto-detect public IP. Set SERVER_IP in the script manually"
  printf '%s\n' "$ip"
}

write_server_config() {
  log "Writing server config ${CONF_DIR}/config.yaml ..."
  cat > "$CONF_DIR/config.yaml" <<EOF
mode: rule
log-level: info
ipv6: true

listeners:
  - name: vless-reality-in
    type: vless
    port: ${VLESS_PORT}
    listen: 0.0.0.0
    users:
      - username: ${VLESS_USER}
        uuid: ${VLESS_UUID}
        flow: xtls-rprx-vision
    reality-config:
      dest: ${REALITY_DEST}
      private-key: ${REALITY_PRIVKEY}
      short-id:
        - ${SHORT_ID}
      server-names:
        - ${REALITY_SERVER_NAME}

  - name: hysteria2-in
    type: hysteria2
    port: ${HY2_PORT}
    listen: 0.0.0.0
    users:
      "${HY2_USER}": "${HY2_PASSWORD}"
    certificate: ${CONF_DIR}/server.crt
    private-key: ${CONF_DIR}/server.key
    alpn:
      - h3
    obfs: salamander
    obfs-password: ${HY2_OBFS_PASSWORD}

  - name: anytls-in
    type: anytls
    port: ${ANYTLS_PORT}
    listen: 0.0.0.0
    users:
      "${ANYTLS_USER}": "${ANYTLS_PASSWORD}"
    certificate: ${CONF_DIR}/server.crt
    private-key: ${CONF_DIR}/server.key

rules:
  - MATCH,DIRECT
EOF
  chmod 600 "$CONF_DIR/config.yaml"
}

write_systemd() {
  log "Writing systemd unit ${SERVICE}.service ..."
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=mihomo daemon (proxy server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MIHOMO_BIN} -d ${CONF_DIR}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

configure_firewall() {
  log "Configuring ufw (allow SSH and the three proxy ports)..."
  # Never lock the operator out: if sshd actually listens elsewhere, allow
  # that port too.
  local sshd_port
  sshd_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
  if [ -n "$sshd_port" ] && [ "$sshd_port" != "$SSH_PORT" ]; then
    warn "sshd listens on ${sshd_port}, not ${SSH_PORT}; allowing ${sshd_port}/tcp as well"
    ufw allow "$sshd_port/tcp" >/dev/null
  fi
  ufw allow "${SSH_PORT}/tcp" >/dev/null
  ufw allow "${VLESS_PORT}/tcp" >/dev/null
  ufw allow "${HY2_PORT}/udp" >/dev/null
  ufw allow "${ANYTLS_PORT}/tcp" >/dev/null
  ufw --force enable >/dev/null
}

enable_bbr() {
  log "Enabling BBR congestion control..."
  cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
}

write_client_artifacts() {
  local ip="$1"
  log "Generating client config and share links..."

  cat > "$CONF_DIR/client.yaml" <<EOF
# Client config snippet (paste/merge into any mihomo Clash client)
proxies:
  - name: "privnet-vless-reality"
    type: vless
    server: "${ip}"
    port: ${VLESS_PORT}
    uuid: "${VLESS_UUID}"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "${REALITY_SERVER_NAME}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${REALITY_PUBKEY}"
      short-id: "${SHORT_ID}"

  - name: "privnet-hy2"
    type: hysteria2
    server: "${ip}"
    port: ${HY2_PORT}
    password: "${HY2_PASSWORD}"
    sni: "${CERT_CN}"
    skip-cert-verify: true
    alpn:
      - h3
    obfs: salamander
    obfs-password: "${HY2_OBFS_PASSWORD}"

  - name: "privnet-anytls"
    type: anytls
    server: "${ip}"
    port: ${ANYTLS_PORT}
    password: "${ANYTLS_PASSWORD}"
    sni: "${CERT_CN}"
    skip-cert-verify: true
    udp: true

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - privnet-vless-reality
      - privnet-hy2
      - privnet-anytls
      - DIRECT

rules:
  - MATCH,PROXY
EOF
  chmod 600 "$CONF_DIR/client.yaml"

  cat > "$CONF_DIR/credentials.txt" <<EOF
======== mihomo proxy server credentials ========
Public IP         : ${ip}
VLESS(Reality) port: ${VLESS_PORT}/tcp  UUID: ${VLESS_UUID}
Hysteria2       port: ${HY2_PORT}/udp    password: ${HY2_PASSWORD}
Hysteria2 obfs  : salamander   obfs-password: ${HY2_OBFS_PASSWORD}
AnyTLS          port: ${ANYTLS_PORT}/tcp password: ${ANYTLS_PASSWORD}
Reality private key: ${REALITY_PRIVKEY}
Reality public key : ${REALITY_PUBKEY}
Reality short ID   : ${SHORT_ID}
Reality camouflage : ${REALITY_SERVER_NAME}
Self-signed cert CN: ${CERT_CN}
========================================
EOF
  chmod 600 "$CONF_DIR/credentials.txt"

  local vless_link hy2_link anytls_link
  vless_link="vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBKEY}&sid=${SHORT_ID}&type=tcp#privnet-vless-reality"
  hy2_link="hy2://${HY2_USER}:${HY2_PASSWORD}@${ip}:${HY2_PORT}/?insecure=1&sni=${CERT_CN}#privnet-hy2"
  anytls_link="anytls://${ANYTLS_PASSWORD}@${ip}:${ANYTLS_PORT}/?insecure=1&sni=${CERT_CN}#privnet-anytls"

  echo
  echo "=================================================="
  echo "  Deployment complete! Share links for client import:"
  echo "=================================================="
  echo
  echo "[1] VLESS + Reality:"
  echo "    ${vless_link}"
  echo
  echo "[2] Hysteria2:"
  echo "    ${hy2_link}"
  echo
  echo "[3] AnyTLS:"
  echo "    ${anytls_link}"
  echo
  echo "Full client YAML: ${CONF_DIR}/client.yaml"
  echo "Credentials backup: ${CONF_DIR}/credentials.txt"
  echo "=================================================="
}

# Wait up to ~5s for $SERVICE to become active.
wait_service_active() {
  local i
  for i in {1..10}; do
    systemctl is-active --quiet "$SERVICE" && return 0
    sleep 0.5
  done
  return 1
}

start_service() {
  log "Starting and enabling ${SERVICE} service..."
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"
  wait_service_active || die "mihomo service failed to start. Check: journalctl -u ${SERVICE} -n 50"
  log "mihomo service is running."
}

cmd_install() {
  case "${1:-}" in
    -h|--help) usage_install; return 0 ;;
  esac
  require_root

  if [ -s "$CONF_DIR/config.yaml" ]; then
    die "Already installed (${CONF_DIR}/config.yaml exists). Run 'privnet.sh uninstall' first to reinstall"
  fi

  detect_os
  detect_arch
  install_deps
  install -d "$(dirname "$MIHOMO_BIN")"
  download_mihomo "$MIHOMO_VERSION" "${MIHOMO_BIN}.new"
  mv -f "${MIHOMO_BIN}.new" "$MIHOMO_BIN"
  gen_credentials
  gen_cert
  write_server_config
  write_systemd
  configure_firewall
  enable_bbr

  local ip
  ip=$(detect_server_ip)
  write_client_artifacts "$ip"
  start_service

  echo
  log "All done. Make sure the cloud firewall / security group also allows these ports."
}

################################################################################
# update
################################################################################

usage_update() {
  cat <<'EOF'
Usage: privnet.sh update [VERSION]

Updates mihomo to the latest release, or to a pinned version
(e.g. privnet.sh update v1.19.10). Config and credentials are kept.
EOF
}

cmd_update() {
  case "${1:-}" in
    -h|--help) usage_update; return 0 ;;
  esac
  local ver="${1:-latest}"

  require_root
  [ -x "$MIHOMO_BIN" ] || die "mihomo not found at ${MIHOMO_BIN}. Run 'privnet.sh install' first"

  local cur
  cur=$("$MIHOMO_BIN" -v 2>/dev/null | head -n1 || true)
  log "Current version: ${cur:-unknown}"

  detect_arch
  download_mihomo "$ver" "${MIHOMO_BIN}.new"
  mv -f "${MIHOMO_BIN}.new" "$MIHOMO_BIN"

  log "Restarting ${SERVICE} service..."
  systemctl restart "$SERVICE"
  wait_service_active || die "Service failed to restart. Check: journalctl -u ${SERVICE} -n 50"

  local new_ver
  new_ver=$("$MIHOMO_BIN" -v 2>/dev/null | head -n1 || true)
  log "Update complete. Current version: ${new_ver:-unknown}"
}

################################################################################
# uninstall
################################################################################

usage_uninstall() {
  cat <<'EOF'
Usage: privnet.sh uninstall

Stops and removes the mihomo service, config, binary, sysctl settings and
firewall rules (run as root with sudo).
EOF
}

# Echo the port of the named listener in $CONF_DIR/config.yaml, if present.
port_from_config() {
  [ -s "$CONF_DIR/config.yaml" ] || return 0
  awk -v name="$1" '$0 ~ "name: " name {f=1} f && /port:/ {print $2; exit}' "$CONF_DIR/config.yaml"
}

cmd_uninstall() {
  case "${1:-}" in
    -h|--help) usage_uninstall; return 0 ;;
  esac
  require_root

  # Reuse the ports from the installed config so the right firewall rules are
  # removed even when the defaults were changed.
  local vless_port hy2_port anytls_port
  vless_port=$(port_from_config vless-reality-in)
  hy2_port=$(port_from_config hysteria2-in)
  anytls_port=$(port_from_config anytls-in)
  vless_port="${vless_port:-443}"
  hy2_port="${hy2_port:-8443}"
  anytls_port="${anytls_port:-9443}"

  log "Stopping and disabling ${SERVICE} service..."
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true

  log "Removing systemd unit..."
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload 2>/dev/null || true

  log "Removing config files, binary and sysctl settings..."
  rm -rf "$CONF_DIR"
  rm -f "$MIHOMO_BIN"
  rm -f "$SYSCTL_FILE"
  sysctl --system >/dev/null 2>&1 || true

  log "Removing firewall rules (keeping SSH)..."
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${vless_port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${hy2_port}/udp" >/dev/null 2>&1 || true
    ufw delete allow "${anytls_port}/tcp" >/dev/null 2>&1 || true
  fi

  log "Uninstall complete."
}

################################################################################
# sub
################################################################################

usage_subscription() {
  cat <<'EOF'
Usage: privnet.sh subscription [-g RESOURCE_GROUP] [-o OUTPUT] [-r RULES_FILE]
                               [-p PROTOCOLS] [-6] VM[=LABEL][@v4|@v6] ...

Reads each VM's /etc/mihomo/client.yaml via az run-command and merges the
proxies into one subscription file (default: sub.yaml). VM is the VM name;
it is also used as the resource group name unless -g is given.

LABEL names the VM's nodes and selector group. Default: the last
dash-separated part of the VM name, uppercased (privnet-jp -> JP).
Example: privnet-jp=Tokyo-HK turns into nodes Tokyo-HK-VLESS,
Tokyo-HK-Hy2, Tokyo-HK-AnyTLS and a Tokyo-HK group.

Nodes dial the VM's IPv4 public IP unless the spec says @v6, which dials its
static public IPv6 address instead (the VM must have been deployed
dual-stack, see deploy -p). @v4 restores the default. Measure per region
first: an ISP's route can be better over IPv6 for one region and worse for
another. Any @v6 node turns the subscription's 'ipv6: true' on, which mihomo
requires in order to dial a literal IPv6 address.

Options:
  -g RESOURCE_GROUP   Resource group holding all the named VMs.
  -o OUTPUT           Output file (default: sub.yaml).
  -r RULES_FILE       Extra Clash rules, one per line ('#' comments and
                      blank lines ignored, a leading "- " is optional).
                      They are emitted before the built-in defaults
                      (GEOIP,CN,DIRECT, MATCH,PROXY); including one of
                      those exact lines replaces the default.
                      Default: rules.txt next to this script, if present.
                      Start from examples/rules.example.txt.
  -p, --protocols LIST
                      Which protocols to emit, comma-separated, from
                      vless, hy2, anytls (default: all three). 'all' is a
                      shorthand for all three, and the order that the nodes
                      appear in each selector group always follows the
                      server's own order, not this list.
                      Use it to leave out nodes a client cannot handle, e.g.
                      '-p vless,anytls' for a client whose Hysteria2 is
                      broken, so the selector never lands on a dead node.
  -6, --ipv6          Same as adding @v6 to every VM spec; an explicit @v4
                      on a VM spec still wins for that VM.
  -h                  Show this help.

Examples:
  privnet.sh subscription -6 privnet-jp privnet-hk=HK privnet-sg=SG@v4
  privnet.sh subscription -p vless,anytls privnet-jp@v6 privnet-sg

The output contains plaintext credentials and is written with mode 600.
EOF
}

label_of() {
  printf '%s' "$1" | awk -F- '{print $NF}' | tr '[:lower:]' '[:upper:]'
}

# Protocols an installed server serves, in the order their stanzas appear in
# client.yaml; the suffix each one's node name gets.
PROTO_KEYS=(vless hy2 anytls)
PROTO_SUFFIXES=(VLESS Hy2 AnyTLS)

# Normalise a user protocol list (e.g. "VLESS,anytls") into the
# space-separated keys of $PROTOCOLS; dies on anything unrecognised.
set_protocols() {
  local raw="$1" p seen="" list
  case "$raw" in
    all|ALL|All) PROTOCOLS="vless hy2 anytls"; return 0 ;;
  esac
  list=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')
  for p in $list; do
    case "$p" in
      vless|hy2|anytls) ;;
      *) die "Unknown protocol '${p}' in '${raw}': choose from vless, hy2, anytls or all" ;;
    esac
    case " $seen " in *" $p "*) ;; *) seen="${seen} ${p}" ;; esac
  done
  [ -n "$seen" ] || die "No protocol selected in '${raw}': choose from vless, hy2, anytls or all"
  PROTOCOLS="${seen# }"
}

# Echo a VM's static public IPv6 address; dies when it has none.
vm_public_ipv6() {
  local rg="$1" vm="$2" ipv6=""
  # deploy names the IPv6 public IP "<vm>-v6"; fall back to any IPv6 public IP
  # in the group for manually created ones.
  ipv6=$(az network public-ip show -g "$rg" -n "${vm}-v6" \
    --query ipAddress -o tsv 2>/dev/null || true)
  if [ -z "$ipv6" ] || [ "$ipv6" = "None" ]; then
    ipv6=$(az network public-ip list -g "$rg" \
      --query "[?publicIPAddressVersion=='IPv6'].ipAddress | [0]" -o tsv 2>/dev/null || true)
  fi
  if [ -z "$ipv6" ] || [ "$ipv6" = "None" ]; then
    die "VM '${vm}' (group ${rg}) has no public IPv6 address. Deploy it dual-stack first (deploy -p <v6-prefix>)."
  fi
  printf '%s\n' "$ipv6"
}

# Fetch the 3 proxy stanzas from a VM's client.yaml and relabel their names.
# $3: "v6" points the nodes at the VM's public IPv6 address (default: v4).
# Keeps only the protocols in $PROTOCOLS (a global set by set_protocols).
fetch_proxies() {
  local vm="$1" label="$2" family="${3:-v4}"
  local rg="${RG:-$vm}"
  local stderr_file stderr_text detail proxies ipv6=""
  stderr_file=$(mktemp /tmp/privnet-az.XXXXXX)
  if ! proxies=$(run_command_stdout "$rg" "$vm" \
        "awk '/^proxies:/{f=1; next} /^proxy-groups:/{f=0} f' /etc/mihomo/client.yaml" \
        "$stderr_file"); then
    stderr_text=$(cat "$stderr_file")
    detail=$(tail -n1 "$stderr_file")
    rm -f "$stderr_file"
    case "$stderr_text" in
      *"not found"*|*NotFound*|*"be found"*)
        warn "VM '${vm}' was not found in resource group '${rg}'"
        die "If each VM lives in its own resource group named after the VM, omit -g; otherwise pass the group that contains it."
        ;;
    esac
    die "Cannot read client.yaml from ${vm} (group ${rg}): ${detail:-az run-command failed}"
  fi
  rm -f "$stderr_file"
  # Relabel the proxy names with this VM's label and keep only the protocols
  # asked for. Each stanza starts at its "name:" line, so buffer one at a
  # time and flush it when the next starts (or at EOF).
  proxies=$(printf '%s\n' "$proxies" | awk -v t="$label" -v sel="$PROTOCOLS" '
    BEGIN { n = split(sel, p, " "); for (i = 1; i <= n; i++) want[p[i]] = 1 }
    /^[[:space:]]*-[[:space:]]*name:/ {
      flush()
      body = $0 "\n"; keep = 0; pending = 1; kind = ""
      if      ($0 ~ /privnet-vless-reality/) { kind = "vless";  suffix = "VLESS" }
      else if ($0 ~ /privnet-hy2/)           { kind = "hy2";    suffix = "Hy2" }
      else if ($0 ~ /privnet-anytls/)        { kind = "anytls"; suffix = "AnyTLS" }
      if (kind != "" && want[kind]) {
        gsub(/privnet-vless-reality|privnet-hy2|privnet-anytls/, t "-" suffix, body)
        keep = 1
      }
      next
    }
    pending { body = body $0 "\n" }
    END { flush() }
    function flush() { if (pending && keep) printf "%s", body; pending = 0 }
  ' \
    | sed '/^[[:space:]]*$/d')
  # Guard against az output-format drift corrupting the subscription.
  case "$proxies" in
    *"[stdout]"*|*"[stderr]"*|*"Enable succeeded"*)
      die "Unexpected az output while reading ${vm}; refusing to write a broken subscription" ;;
  esac
  [ -n "$proxies" ] || die "No ${PROTOCOLS// /, } nodes found on ${vm} (group ${rg}). Is mihomo installed there with those protocols enabled?"
  if [ "$family" = "v6" ]; then
    ipv6=$(vm_public_ipv6 "$rg" "$vm")
    proxies=$(printf '%s\n' "$proxies" \
      | sed -E "s|^([[:space:]]*server:)[[:space:]]*.*\$|\1 \"${ipv6}\"|")
  fi
  printf '%s\n' "$proxies"
}

cmd_subscription() {
  local output="sub.yaml" rules_file="" opt
  local default_family="v4" spec="" family="" arg0="" sub_ipv6="false"
  local -a argv=()
  RG=""
  PROTOCOLS="vless hy2 anytls"
  # getopts has no long options; accept the long spellings here.
  for arg0 in "$@"; do
    case "$arg0" in
      --ipv6)            argv+=("-6") ;;
      --ipv6=*)          die "--ipv6 takes no value; add @v6 to individual VM specs instead" ;;
      --protocols)       argv+=("-p") ;;
      --protocols=*)     argv+=("-p" "${arg0#--protocols=}") ;;
      *)                 argv+=("$arg0") ;;
    esac
  done
  if [ "${#argv[@]}" -gt 0 ]; then
    set -- "${argv[@]}"
  fi
  while getopts "g:o:r:p:6h" opt; do
    case "$opt" in
      g) RG="$OPTARG" ;;
      o) output="$OPTARG" ;;
      r) rules_file="$OPTARG" ;;
      p) set_protocols "$OPTARG" ;;
      6) default_family="v6" ;;
      h) usage_subscription; return 0 ;;
      *) usage_subscription >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))
  [ "$#" -gt 0 ] || { echo "error: at least one VM name is required" >&2; usage_subscription >&2; exit 2; }

  local name label arg base dup idx pid failed line cr
  local -a names=() labels=() families=() pids=() custom_rules=()
  for arg in "$@"; do
    spec="$arg"
    family=""
    case "$arg" in
      *@*) family="${arg##*@}" ;;
    esac
    case "$family" in
      ""|v4|v6) ;;
      *) die "Invalid address family '@${family}' in '${spec}': use @v4 or @v6" ;;
    esac
    base="${arg%@*}"
    case "$base" in
      *=*) name="${base%%=*}"; label="${base#*=}" ;;
      *)   name="$base";        label="$(label_of "$name")" ;;
    esac
    [ -n "$name" ] || die "Invalid server spec '${spec}': empty VM name"
    [ -n "$label" ] || die "Invalid server spec '${spec}': empty label (use VM=LABEL)"
    case "$label" in
      *@*) die "Invalid label '${label}' in '${spec}': '@' is reserved for the @v4/@v6 suffix" ;;
      *[[:space:]]*|*'"'*|*=*)
        die "Invalid label '${label}' in '${arg}': no whitespace, quote or '=' characters" ;;
    esac
    names+=("$name")
    labels+=("$label")
    families+=("${family:-$default_family}")
  done
  # Nodes are dialed by literal address, and mihomo only dials a literal IPv6
  # address when ipv6 is enabled, so the header has to follow the node specs.
  for family in "${families[@]}"; do
    if [ "$family" = "v6" ]; then sub_ipv6="true"; fi
  done

  dup=$(printf '%s\n' "${labels[@]}" | sort | uniq -d)
  [ -z "$dup" ] || die "Duplicate label(s): $(printf '%s' "$dup" | tr '\n' ' ') - use distinct VM names or explicit LABELs"

  # A rules file next to the script is personal config (gitignored) and is
  # used automatically; -r picks a different file.
  if [ -z "$rules_file" ] && [ -f "${SELF_DIR}/rules.txt" ]; then
    rules_file="${SELF_DIR}/rules.txt"
    log "Using ${rules_file} (override: -r FILE)"
  fi

  if [ -n "$rules_file" ]; then
    [ -r "$rules_file" ] || die "Rules file not found: ${rules_file}"
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "${line%$'\r'}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -n "$line" ] || continue
      case "$line" in \#*) continue ;; esac
      custom_rules+=("${line#- }")
    done < "$rules_file"
    log "Loaded ${#custom_rules[@]} custom rule(s) from ${rules_file}"
  fi
  local have_geoip=0 have_match=0
  if [ "${#custom_rules[@]}" -gt 0 ]; then
    for cr in "${custom_rules[@]}"; do
      case "$cr" in GEOIP,CN,DIRECT) have_geoip=1 ;; esac
      case "$cr" in MATCH,*) have_match=1 ;; esac
    done
  fi

  # Fetch every VM in parallel: each az run-command round-trip costs seconds
  # and the VMs are independent. Results land in $SUB_DIR in argument order.
  log "Protocols: ${PROTOCOLS// /, }"
  # These are script-level, not locals: a trap set inside a function runs
  # after the function has returned, when its locals are gone, so an EXIT trap
  # referencing locals would clean up nothing.
  SUB_TMP=""
  SUB_DIR=$(mktemp -d /tmp/privnet-sub.XXXXXX) || die "Cannot create a temporary directory"
  trap 'rm -f "${SUB_TMP:-}"; rm -rf "${SUB_DIR:-}"' EXIT

  idx=0
  for name in "${names[@]}"; do
    log "Reading proxies from ${name} (label: ${labels[$idx]}, ${families[$idx]})"
    ( fetch_proxies "$name" "${labels[$idx]}" "${families[$idx]}" > "${SUB_DIR}/${idx}" ) &
    pids+=("$!")
    idx=$((idx + 1))
  done
  failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  [ "$failed" -eq 0 ] || die "Failed to read proxies from one or more VMs"

  # Write to a temp file first so a failed read never leaves a partial
  # subscription behind.
  SUB_TMP=$(mktemp "${output}.XXXXXX") || die "Cannot create a temporary file next to ${output}"

  {
    echo "# privnet subscription"
    echo "mixed-port: 7890"
    echo "allow-lan: false"
    echo "mode: rule"
    echo "log-level: info"
    echo "ipv6: ${sub_ipv6}"
    echo
    echo "proxies:"

    idx=0
    for name in "${names[@]}"; do
      cat "${SUB_DIR}/${idx}"
      idx=$((idx + 1))
    done

    echo
    echo "proxy-groups:"
    echo '  - name: "PROXY"'
    echo '    type: select'
    echo '    proxies:'
    for label in "${labels[@]}"; do
      echo "      - \"${label}\""
    done
    echo '      - DIRECT'
    echo
    for label in "${labels[@]}"; do
      echo "  - name: \"${label}\""
      echo '    type: select'
      echo '    proxies:'
      for i in "${!PROTO_KEYS[@]}"; do
        case " ${PROTOCOLS} " in
          *" ${PROTO_KEYS[$i]} "*) echo "      - \"${label}-${PROTO_SUFFIXES[$i]}\"" ;;
        esac
      done
      echo
    done

    echo "rules:"
    if [ "${#custom_rules[@]}" -gt 0 ]; then
      for cr in "${custom_rules[@]}"; do
        echo "  - ${cr}"
      done
    fi
    [ "$have_geoip" -eq 1 ] || echo "  - GEOIP,CN,DIRECT"
    [ "$have_match" -eq 1 ] || echo "  - MATCH,PROXY"
  } > "$SUB_TMP"

  chmod 600 "$SUB_TMP"
  mv -f "$SUB_TMP" "$output"
  log "Subscription written to ${output} (mode 600)"
}

################################################################################
# vm
################################################################################

usage_deploy() {
  cat <<'EOF'
Usage: privnet.sh deploy -g RESOURCE_GROUP -l LOCATION -n NAME [options]

Provisions a resource group, NSG, VNet, static public IP, NIC (accelerated
networking) and a Debian 12 arm64 VM, then deploys the proxy on it.

Required:
  -g RESOURCE_GROUP   Azure resource group name.
  -l LOCATION         Azure location, e.g. japaneast.
  -n NAME             Name shared by the VM and its resources
                      (NSG, VNet, PIP, NIC, disk).

Options:
  -u USER             VM admin username (default: current user).
  -k PUBKEY           SSH public key path (default: first found of
                      ~/.ssh/id_ed25519.pub, ~/.ssh/id_rsa.pub).
  -K PRIVKEY          SSH private key path (default: derived from -k).
  -s SIZE             VM size (default: Standard_B2pls_v2).
  -i IMAGE            VM image (default: Debian:debian-12:12-arm64:latest).
  -z ZONE             Availability zone, e.g. 1 (default: none).
  -t PORT             SSH port for the NSG rule (default: 22; must match
                      the server's sshd port).
  -v PORT             VLESS/Reality port (default: 443; NSG and server).
  -y PORT             Hysteria2 port (default: 8443; NSG and server).
  -a PORT             AnyTLS port (default: 9443; NSG and server).
  -6                  Provision a dual-stack (IPv4 + IPv6) VNet and VM,
                      giving the VM an IPv6 address for IPv6-only
                      destinations. Requires -p.
  -p V6PREFIX         VNet IPv6 address space: a GUA block you control,
                      sized /48, /52 or /56, e.g. 2a11:6f3c:9d2e::/48.
                      The first /64 of the block is used as the subnet.
                      Implies -6.
  -h                  Show this help and exit.

Environment variables (optional overrides):
  VNET_PREFIX         VNet address space (default: 10.0.0.0/16).
  SUBNET_PREFIX       Subnet address prefix (default: 10.0.0.0/24).
  PRIVNET_MIHOMO_VERSION  mihomo release to install (default: latest).

Note:
  Azure resource names are unique per resource type, so NSG/VNet/PIP/NIC/VM
  can all reuse the same -n name. One VM per run; run once per region with a
  distinct -n name.
EOF
}

# Returns 0 (true) if the given az resource exists.
resource_exists() {
  az "$@" --query name -o tsv 2>/dev/null | grep -q .
}

# Create a resource, retrying while Azure reports ResourceNotFound: right
# after a resource group with the same name was deleted and recreated, the
# old deletion tombstone makes the first creates return transient 404s.
az_create_retry() {
  local err attempt
  for attempt in {1..10}; do
    if err=$(az "$@" 2>&1); then
      return 0
    fi
    case "$err" in
      *ResourceNotFound*)
        if [ "$attempt" -lt 10 ]; then
          warn "Azure is still settling ${RG} (recently deleted?); retrying in 30s (${attempt}/10)"
          sleep 30
          continue
        fi
        ;;
    esac
    break
  done
  printf '%s\n' "$err" >&2
  return 1
}

# Build a run-command wrapper that embeds this script on the VM and runs a
# subcommand; used when SSH is not reachable. $4, if given, is a string of
# VAR=value pairs passed to the subcommand.
make_remote_installer() {
  local wrapper="$1" remote="$2" subcmd="$3" env="${4:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf "cat > %s <<'PRIVNET_SCRIPT'\n" "$remote"
    cat "$SELF_PATH"
    printf 'PRIVNET_SCRIPT\n'
    printf '%s bash %s %s\n' "$env" "$remote" "$subcmd"
  } > "$wrapper"
}

cmd_deploy() {
  RG=""
  LOCATION=""
  RESOURCE_NAME=""
  ADMIN_USER="${USER:-root}"
  SSH_PUBKEY=""
  SSH_KEY=""
  VM_SIZE="Standard_B2pls_v2"
  IMAGE="Debian:debian-12:12-arm64:latest"
  ZONE=""
  VNET_PREFIX="${VNET_PREFIX:-10.0.0.0/16}"
  SUBNET_PREFIX="${SUBNET_PREFIX:-10.0.0.0/24}"
  IPV6=0
  IPV6_PREFIX=""
  IPV6_SUBNET=""

  local opt
  while getopts "g:l:n:u:k:K:s:i:z:t:v:y:a:p:6h" opt; do
    case "$opt" in
      g) RG="$OPTARG" ;;
      l) LOCATION="$OPTARG" ;;
      n) RESOURCE_NAME="$OPTARG" ;;
      u) ADMIN_USER="$OPTARG" ;;
      k) SSH_PUBKEY="$OPTARG" ;;
      K) SSH_KEY="$OPTARG" ;;
      s) VM_SIZE="$OPTARG" ;;
      i) IMAGE="$OPTARG" ;;
      z) ZONE="$OPTARG" ;;
      t) SSH_PORT="$OPTARG" ;;
      v) VLESS_PORT="$OPTARG" ;;
      y) HY2_PORT="$OPTARG" ;;
      a) ANYTLS_PORT="$OPTARG" ;;
      6) IPV6=1 ;;
      p) IPV6=1; IPV6_PREFIX="$OPTARG" ;;
      h) usage_deploy; return 0 ;;
      *) usage_deploy >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  [ -n "$RG" ]            || { echo "error: -g RESOURCE_GROUP is required" >&2; usage_deploy >&2; exit 2; }
  [ -n "$LOCATION" ]      || { echo "error: -l LOCATION is required" >&2; usage_deploy >&2; exit 2; }
  [ -n "$RESOURCE_NAME" ] || { echo "error: -n NAME is required" >&2; usage_deploy >&2; exit 2; }

  if [ "$IPV6" -eq 1 ]; then
    [ -n "$IPV6_PREFIX" ] || { echo "error: -6 requires -p V6PREFIX (e.g. -p 2a11:6f3c:9d2e::/48)" >&2; usage_deploy >&2; exit 2; }
    case "$IPV6_PREFIX" in
      *:*/48|*:*/52|*:*/56) ;;
      *) die "Invalid IPv6 prefix '${IPV6_PREFIX}': Azure requires the VNet IPv6 space to be a GUA block sized /48, /52 or /56 (e.g. 2a11:6f3c:9d2e::/48)" ;;
    esac
    # The subnet must be exactly /64; take the first /64 of the block.
    IPV6_SUBNET="${IPV6_PREFIX%/*}/64"
  fi

  command -v az  >/dev/null 2>&1 || die "Azure CLI not found. Install it first: https://learn.microsoft.com/cli/azure/install-azure-cli"
  command -v ssh >/dev/null 2>&1 || die "ssh not found"
  command -v scp >/dev/null 2>&1 || die "scp not found"

  az account show --output none >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login"

  if [ -z "$SSH_PUBKEY" ]; then
    for candidate in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
      if [ -f "$candidate" ]; then
        SSH_PUBKEY="$candidate"
        break
      fi
    done
  fi
  [ -n "$SSH_PUBKEY" ] || die "No SSH public key found (looked for ~/.ssh/id_ed25519.pub and ~/.ssh/id_rsa.pub). Create one with 'ssh-keygen -t ed25519' or pass -k PUBKEY."
  [ -n "$SSH_KEY" ] || SSH_KEY="${SSH_PUBKEY%.pub}"
  [ -f "$SSH_PUBKEY" ] || die "Public key not found: ${SSH_PUBKEY}"
  [ -f "$SSH_KEY" ]    || die "Private key not found: ${SSH_KEY}"

  log "Creating resource group ${RG} (${LOCATION})"
  # If a same-named RG is still being deleted (e.g. after a previous run with
  # async delete), wait for deletion to finish; otherwise child resources fail
  # with a transient ResourceNotFound.
  local state i
  for i in {1..30}; do
    state=$(az group show -n "$RG" --query properties.provisioningState -o tsv 2>/dev/null || true)
    [ "$state" != "Deleting" ] && break
    warn "Resource group ${RG} is still being deleted; waiting 10s... (${i}/30)"
    sleep 10
    if [ "$i" -eq 30 ]; then
      die "Resource group ${RG} has not finished deleting after 5 minutes. Try again later."
    fi
  done
  az group create -n "$RG" -l "$LOCATION" --output none
  # If provisioning fails partway, the resources already created need cleanup.
  trap 'warn "Deploy failed; partial resources may remain. Clean up with: az group delete -n ${RG} --yes"' ERR

  local name="$RESOURCE_NAME"

  # az create is idempotent, so fail fast when any target resource already
  # exists instead of silently updating/overwriting it.
  if resource_exists network nsg show -g "$RG" -n "$name" \
  || resource_exists network vnet show -g "$RG" -n "$name" \
  || resource_exists network public-ip show -g "$RG" -n "$name" \
  || { [ "$IPV6" -eq 1 ] && resource_exists network public-ip show -g "$RG" -n "${name}-v6"; } \
  || resource_exists network nic show -g "$RG" -n "$name" \
  || resource_exists vm show -g "$RG" -n "$name"; then
    die "Some resource named '${name}' already exists in ${RG}. Delete them first (az group delete -n ${RG}) or use a different -n name."
  fi

  log "==================== Deploying ${name} (${LOCATION}) ===================="

  log "Creating NSG ${name}"
  az_create_retry network nsg create -g "$RG" -n "$name" -l "$LOCATION" --output none

  az network nsg rule create -g "$RG" --nsg-name "$name" -n SSH \
    --priority 300 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$SSH_PORT" --output none
  az network nsg rule create -g "$RG" --nsg-name "$name" -n VLESS-Reality \
    --priority 310 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$VLESS_PORT" --output none
  az network nsg rule create -g "$RG" --nsg-name "$name" -n Hysteria2 \
    --priority 320 --direction Inbound --access Allow --protocol Udp \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$HY2_PORT" --output none
  az network nsg rule create -g "$RG" --nsg-name "$name" -n AnyTLS \
    --priority 330 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$ANYTLS_PORT" --output none

  log "Creating VNet ${name}"
  if [ "$IPV6" -eq 1 ]; then
    az network vnet create -g "$RG" -n "$name" -l "$LOCATION" \
      --address-prefixes "$VNET_PREFIX" "$IPV6_PREFIX" \
      --subnet-name default --subnet-prefixes "$SUBNET_PREFIX" "$IPV6_SUBNET" --output none
  else
    az network vnet create -g "$RG" -n "$name" -l "$LOCATION" \
      --address-prefixes "$VNET_PREFIX" --subnet-name default --subnet-prefixes "$SUBNET_PREFIX" --output none
  fi

  log "Creating static public IP ${name}"
  if [ -n "$ZONE" ]; then
    az network public-ip create -g "$RG" -n "$name" -l "$LOCATION" \
      --sku Standard --allocation-method Static --zone "$ZONE" --output none
  else
    az network public-ip create -g "$RG" -n "$name" -l "$LOCATION" \
      --sku Standard --allocation-method Static --output none
  fi

  if [ "$IPV6" -eq 1 ]; then
    log "Creating static IPv6 public IP ${name}-v6"
    if [ -n "$ZONE" ]; then
      az network public-ip create -g "$RG" -n "${name}-v6" -l "$LOCATION" \
        --sku Standard --allocation-method Static --version IPv6 --zone "$ZONE" --output none
    else
      az network public-ip create -g "$RG" -n "${name}-v6" -l "$LOCATION" \
        --sku Standard --allocation-method Static --version IPv6 --output none
    fi
  fi

  log "Creating NIC ${name} (accelerated networking enabled)"
  az network nic create -g "$RG" -n "$name" -l "$LOCATION" \
    --vnet-name "$name" --subnet default \
    --network-security-group "$name" --public-ip-address "$name" \
    --accelerated-networking true --output none

  if [ "$IPV6" -eq 1 ]; then
    log "Adding IPv6 IP configuration to NIC ${name}"
    az network nic ip-config create -g "$RG" --nic-name "$name" -n ipconfig2 \
      --private-ip-address-version IPv6 \
      --vnet-name "$name" --subnet default \
      --public-ip-address "${name}-v6" --output none
  fi

  log "Creating VM ${name}"
  if [ -n "$ZONE" ]; then
    az vm create -g "$RG" -n "$name" --location "$LOCATION" --nics "$name" \
      --image "$IMAGE" --size "$VM_SIZE" --os-disk-name "$name" \
      --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_PUBKEY" \
      --zone "$ZONE" --output none
  else
    az vm create -g "$RG" -n "$name" --location "$LOCATION" --nics "$name" \
      --image "$IMAGE" --size "$VM_SIZE" --os-disk-name "$name" \
      --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_PUBKEY" \
      --output none
  fi

  local ip
  ip=$(az network public-ip show -g "$RG" -n "$name" --query ipAddress -o tsv)
  [ -n "$ip" ] && [ "$ip" != "None" ] || die "Failed to get public IP for ${name}"
  log "${name} public IP: ${ip}"

  log "Waiting for SSH to become ready..."
  local n=0
  until ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
        "$ADMIN_USER@$ip" true >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -ge 12 ]; then
      warn "SSH not reachable within 60s (possibly blocked); falling back to run-command deploy."
      break
    fi
    [ $((n % 6)) -eq 0 ] && log "Still waiting for SSH (${n}/12)..."
    sleep 5
  done

  # Ports and the mihomo version chosen on the deploy side must reach the
  # installer, or the NSG and the server listeners would disagree.
  local remote_env="PRIVNET_SSH_PORT=${SSH_PORT} PRIVNET_VLESS_PORT=${VLESS_PORT} PRIVNET_HY2_PORT=${HY2_PORT} PRIVNET_ANYTLS_PORT=${ANYTLS_PORT} PRIVNET_MIHOMO_VERSION=${MIHOMO_VERSION}"

  if [ "$n" -lt 12 ]; then
    log "Uploading ${SELF_PATH} to ${name}"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
      "$SELF_PATH" "$ADMIN_USER@$ip:~/privnet.sh"

    log "Running install on ${name} as root..."
    az vm run-command invoke -g "$RG" -n "$name" --command-id RunShellScript \
      --scripts "${remote_env} bash /home/${ADMIN_USER}/privnet.sh install" \
      --query "value[0].message" -o tsv
  else
    log "Deploying install on ${name} via run-command (no SSH needed)..."
    local wrapper ok=0 attempt
    wrapper=$(mktemp /tmp/privnet-wrapper.XXXXXX)
    make_remote_installer "$wrapper" /root/privnet.sh install "$remote_env"
    for attempt in 1 2 3; do
      if az vm run-command invoke -g "$RG" -n "$name" --command-id RunShellScript \
           --scripts "@${wrapper}" \
           --query "value[0].message" -o tsv; then
        ok=1
        break
      fi
      [ "$attempt" -lt 3 ] && { warn "run-command attempt ${attempt} failed; retrying in 20s..."; sleep 20; }
    done
    rm -f "$wrapper"
    [ "$ok" -eq 1 ] || die "Deployment via run-command failed after 3 attempts"
  fi

  verify_service_active "$RG" "$name"

  log "==================== All done ===================="
  log "Next: bash ${SELF_PATH} subscription -g ${RG} ${name}"
  log "Cleanup: az group delete -n ${RG} --yes"
}

################################################################################
# Dispatch
################################################################################

usage() {
  cat <<'EOF'
Usage: privnet.sh <command> [options]

Commands:
  deploy        Provision an Azure VM and deploy the proxy on it
  install       Install and configure mihomo on this machine (run as root)
  update        Update mihomo on this machine (run as root)
  uninstall     Remove mihomo from this machine (run as root)
  subscription  Generate a Clash subscription from deployed VMs
  help          Show this help

Run 'privnet.sh <command> -h' for command-specific options.
EOF
}

main() {
  local cmd="${1:-help}"
  if [ $# -gt 0 ]; then
    shift
  fi
  case "$cmd" in
    deploy)
      TAG=deploy
      cmd_deploy "$@"
      ;;
    install)
      TAG=install
      cmd_install "$@"
      ;;
    update)
      TAG=update
      cmd_update "$@"
      ;;
    uninstall)
      TAG=uninstall
      cmd_uninstall "$@"
      ;;
    subscription)
      TAG=subscription
      cmd_subscription "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      die "Unknown command: ${cmd}"
      ;;
  esac
}

# Run the CLI when executed directly; stay inert when sourced (tests).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
