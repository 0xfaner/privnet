#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="${SELF_DIR}/$(basename "${BASH_SOURCE[0]}")"

TAG="privnet"

MIHOMO_BIN="/usr/local/bin/mihomo"
CONF_DIR="/etc/mihomo"
SERVICE="mihomo"
SYSCTL_FILE="/etc/sysctl.d/99-privnet-bbr.conf"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
LOCK_FILE="/run/privnet.lock"

VLESS_PORT="${PRIVNET_VLESS_PORT:-443}"       # VLESS + Reality (TCP)
HY2_PORT="${PRIVNET_HY2_PORT:-8443}"          # Hysteria2 (UDP)
ANYTLS_PORT="${PRIVNET_ANYTLS_PORT:-9443}"    # AnyTLS (TCP)

SSH_PORT="${PRIVNET_SSH_PORT:-22}"
PRINT_LINKS="${PRIVNET_PRINT_LINKS:-1}"
REALITY_SERVER_NAME="www.microsoft.com"
REALITY_DEST="${REALITY_SERVER_NAME}:443"
CERT_CN="mihomo.local"
SERVER_IP="${PRIVNET_SERVER_IP:-}"
MIHOMO_VERSION="${PRIVNET_MIHOMO_VERSION:-latest}"
VLESS_USER="vless"
HY2_USER="hy2"
ANYTLS_USER="anytls"

log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$TAG" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$TAG" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$TAG" "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root: sudo bash ${SELF_PATH} ${TAG}"
}

detect_os() {
  [ -r /etc/os-release ] || die "Missing /etc/os-release"
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) log "Detected ${ID} ${VERSION_ID:-}" ;;
    *) die "Unsupported OS: ${ID:-unknown}. Use Debian or Ubuntu." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m) (only amd64 / arm64)" ;;
  esac
}

lock_server() {
  exec 9>>"$LOCK_FILE"
  flock -n 9 || die "Another privnet operation is running"
}

validate_ports() {
  local port
  for port in "$SSH_PORT" "$VLESS_PORT" "$HY2_PORT" "$ANYTLS_PORT"; do
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] \
      || die "Invalid port '$port': expected a number from 1 to 65535"
  done
  [ "$VLESS_PORT" != "$ANYTLS_PORT" ] && [ "$SSH_PORT" != "$VLESS_PORT" ] \
    && [ "$SSH_PORT" != "$ANYTLS_PORT" ] || die "SSH, VLESS and AnyTLS need distinct TCP ports"
}

validate_version() {
  [[ "$1" =~ ^(latest|v[0-9][a-zA-Z0-9._-]*)$ ]] \
    || die "Invalid mihomo version '$1': expected latest or a release tag such as v1.19.10"
}

# Download to a caller-owned staging directory. Verify the GitHub release
# digest before unpacking or executing the asset.
download_mihomo() (
  local requested="$1" dest="$2" ver release asset candidate digest actual
  local api="https://api.github.com/repos/MetaCubeX/mihomo/releases"
  validate_version "$requested"
  [ "$requested" = latest ] || api="$api/tags"
  release=$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 90 "$api/$requested") \
    || die "Cannot fetch mihomo release '$requested' from GitHub"
  ver=$(jq -er '.tag_name' <<< "$release") || die "Missing tag in mihomo release"
  validate_version "$ver"
  if [[ "$ver" = latest || ( "$requested" != latest && "$requested" != "$ver" ) ]]; then
    die "Unexpected release tag '$ver' for '$requested'"
  fi
  for candidate in \
    "mihomo-linux-${ARCH}-${ver}.gz" \
    "mihomo-linux-${ARCH}-v1-${ver}.gz" \
    "mihomo-linux-${ARCH}-compatible-${ver}.gz"; do
    asset=$(jq -c --arg name "$candidate" '.assets[] | select(.name == $name)' <<< "$release")
    [ -z "$asset" ] || break
  done
  [ -n "$asset" ] || die "No mihomo binary found for architecture ${ARCH} in release ${ver}"
  digest=$(jq -er '.digest' <<< "$asset") || die "No digest for ${candidate}"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Invalid SHA-256 digest for ${candidate}"

  log "Downloading ${candidate}"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 -o "${dest}.gz" \
    "https://github.com/MetaCubeX/mihomo/releases/download/${ver}/${candidate}"
  actual=$(sha256sum < "${dest}.gz")
  [ "${actual%% *}" = "${digest#sha256:}" ] \
    || die "SHA-256 verification failed for ${candidate}"
  gzip -dc "${dest}.gz" > "$dest"
  rm -f "${dest}.gz"
  chmod 755 "$dest"
  "$dest" -v >/dev/null 2>&1 || die "Downloaded mihomo binary cannot execute"
)

vm_run_command() {
  az vm run-command invoke -g "$1" -n "$2" --command-id RunShellScript \
    --scripts "$3" --query "value[0].message" -o tsv
}

remote_stdout() {
  awk '/^\[stdout\]/{out=1; next} /^\[stderr\]/{out=0} out'
}

# install

usage_install() {
  cat <<EOF
Usage: privnet.sh install

Installs and configures mihomo on this machine (run as root with sudo).

Settings live at the top of this script; each can be overridden via the
environment (PRIVNET_VLESS_PORT, PRIVNET_HY2_PORT, PRIVNET_ANYTLS_PORT,
PRIVNET_SSH_PORT, PRIVNET_MIHOMO_VERSION, PRIVNET_SERVER_IP,
PRIVNET_PRINT_LINKS):
  ports:    VLESS ${VLESS_PORT}/tcp, Hysteria2 ${HY2_PORT}/udp, AnyTLS ${ANYTLS_PORT}/tcp
  firewall: SSH ${SSH_PORT}/tcp
EOF
}

install_deps() {
  log "Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get -o DPkg::Lock::Timeout=120 install -y "$@" >/dev/null
}

gen_credentials() {
  log "Generating credentials..."
  if [ -r /proc/sys/kernel/random/uuid ]; then
    VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
  else
    VLESS_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  fi
  HY2_PASSWORD=$(openssl rand -hex 16)
  HY2_OBFS_PASSWORD=$(openssl rand -hex 16)
  ANYTLS_PASSWORD=$(openssl rand -hex 16)
  SHORT_ID=$(openssl rand -hex 8)

  local kp
  kp=$("${1:-$MIHOMO_BIN}" generate reality-keypair) || die "Failed to generate Reality keypair"
  REALITY_PRIVKEY=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey: *//p')
  REALITY_PUBKEY=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey: *//p')
  [ -n "$REALITY_PRIVKEY" ] && [ -n "$REALITY_PUBKEY" ] || die "Failed to parse Reality keypair"
}

gen_cert() {
  log "Generating self-signed cert (CN=${CERT_CN}, valid 10 years)..."
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CONF_DIR/server.key" \
    -out "$CONF_DIR/server.crt" \
    -days 3650 \
    -addext "subjectAltName=DNS:${CERT_CN}" \
    -subj "/CN=${CERT_CN}" >/dev/null 2>&1 || die "Failed to generate self-signed cert"
  chmod 600 "$CONF_DIR/server.key"
  chmod 644 "$CONF_DIR/server.crt"
}

cert_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^[^=]*=//; s/://g' | tr 'A-F' 'a-f'
}

detect_server_ip() {
  if [ -n "$SERVER_IP" ]; then
    printf '%s\n' "$SERVER_IP"
    return 0
  fi
  local ip=""
  ip=$(curl -fsS --noproxy "*" -m 5 -H "Metadata:true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" 2>/dev/null || true)
  if [ -z "$ip" ]; then
    ip=$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true)
  fi
  [ -n "$ip" ] || die "Cannot auto-detect public IP. Set PRIVNET_SERVER_IP and rerun install"
  printf '%s\n' "$ip"
}

write_egress_rules() {
  cat <<'EOF'
  - IP-CIDR,0.0.0.0/8,REJECT
  - IP-CIDR,127.0.0.0/8,REJECT
  - IP-CIDR,10.0.0.0/8,REJECT
  - IP-CIDR,172.16.0.0/12,REJECT
  - IP-CIDR,192.168.0.0/16,REJECT
  - IP-CIDR,169.254.0.0/16,REJECT
  - IP-CIDR,168.63.129.16/32,REJECT
  - IP-CIDR6,::/128,REJECT
  - IP-CIDR6,::1/128,REJECT
  - IP-CIDR6,fc00::/7,REJECT
  - IP-CIDR6,fe80::/10,REJECT
EOF
  if [ -n "${1:-}" ]; then
    [[ "$1" =~ ^[a-fA-F0-9:]+/64$ ]] || die "Invalid Azure IPv6 subnet: $1"
    printf '  - IP-CIDR6,%s,REJECT\n' "$1"
  fi
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
    listen: "::"
    users:
      - username: ${VLESS_USER}
        uuid: ${VLESS_UUID}
        flow: xtls-rprx-vision
    reality-config:
      dest: ${REALITY_DEST}
      private-key: ${REALITY_PRIVKEY}
      short-id:
        - "${SHORT_ID}"
      server-names:
        - ${REALITY_SERVER_NAME}

  - name: hysteria2-in
    type: hysteria2
    port: ${HY2_PORT}
    listen: "::"
    users:
      "${HY2_USER}": "${HY2_PASSWORD}"
    certificate: ${CONF_DIR}/server.crt
    private-key: ${CONF_DIR}/server.key
    alpn:
      - h3
    obfs: salamander
    obfs-password: "${HY2_OBFS_PASSWORD}"

  - name: anytls-in
    type: anytls
    port: ${ANYTLS_PORT}
    listen: "::"
    users:
      "${ANYTLS_USER}": "${ANYTLS_PASSWORD}"
    certificate: ${CONF_DIR}/server.crt
    private-key: ${CONF_DIR}/server.key

rules:
$(write_egress_rules "${PRIVNET_VNET_IPV6_SUBNET:-}")
  - MATCH,DIRECT
EOF
  chmod 600 "$CONF_DIR/config.yaml"
}

write_systemd() {
  log "Writing systemd unit ${SERVICE}.service ..."
  cat > "$UNIT_FILE" <<EOF
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
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ReadWritePaths=${CONF_DIR}
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
}

configure_firewall() {
  log "Configuring ufw (allow SSH and the three proxy ports)..."
  # Preserve access when sshd uses a custom port.
  local sshd_port
  sshd_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
  if [ -n "$sshd_port" ] && [ "$sshd_port" != "$SSH_PORT" ]; then
    warn "sshd listens on ${sshd_port}, not ${SSH_PORT}; allowing ${sshd_port}/tcp as well"
    ufw allow "$sshd_port/tcp" >/dev/null
  fi
  ufw allow "${SSH_PORT}/tcp" >/dev/null
  local added rule
  : > "$CONF_DIR/firewall.rules"
  added=$(ufw show added | awk '$1=="ufw" && $2=="allow" && (NF==3 || $4=="comment") {print $3}')
  for rule in "${VLESS_PORT}/tcp" "${HY2_PORT}/udp" "${ANYTLS_PORT}/tcp"; do
    if grep -Fxq "$rule" <<< "$added"; then continue; fi
    printf '%s\n' "$rule" >> "$CONF_DIR/firewall.rules"
    ufw allow "$rule" comment privnet >/dev/null
  done
  ufw --force enable >/dev/null
}

remove_firewall_rules() {
  local record="$CONF_DIR/firewall.rules" rule failed=0
  [ -s "$record" ] || return 0
  command -v ufw >/dev/null 2>&1 || return 1
  while IFS= read -r rule; do
    if ! ufw --force delete allow "$rule" >/dev/null 2>&1; then
      warn "Could not remove ufw rule $rule"
      failed=1
    fi
  done < "$record"
  return "$failed"
}

enable_bbr() {
  log "Enabling BBR congestion control..."
  cat > "$SYSCTL_FILE" <<'EOF' || return 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
}

write_client_header() {
  cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: $1

proxies:
EOF
}

write_client_artifacts() {
  local ip="$1" fingerprint
  fingerprint=$(cert_fingerprint "$CONF_DIR/server.crt")
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || die "Cannot read the TLS certificate fingerprint"
  log "Generating client config..."

  local ipv6=false
  case "$ip" in *:*) ipv6=true ;; esac
  write_client_header "$ipv6" > "$CONF_DIR/client.yaml"
  cat >> "$CONF_DIR/client.yaml" <<EOF
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
    fingerprint: "${fingerprint}"
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
    fingerprint: "${fingerprint}"
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
Reality public key : ${REALITY_PUBKEY}
Reality short ID   : ${SHORT_ID}
Reality camouflage : ${REALITY_SERVER_NAME}
Self-signed cert CN: ${CERT_CN}
========================================
EOF
  chmod 600 "$CONF_DIR/credentials.txt"
}

print_share_links() {
  local ip="$1" fingerprint
  [ "$PRINT_LINKS" = 1 ] || return 0
  fingerprint=$(cert_fingerprint "$CONF_DIR/server.crt")
  case "$ip" in *:*) ip="[$ip]" ;; esac
  printf '\nVLESS + Reality:\n  %s\n' \
    "vless://${VLESS_UUID}@${ip}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBKEY}&sid=${SHORT_ID}&type=tcp#privnet-vless-reality"
  printf 'Hysteria2:\n  %s\n' \
    "hy2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?insecure=1&sni=${CERT_CN}&pinSHA256=${fingerprint}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}#privnet-hy2"
  printf 'Full client YAML (includes AnyTLS): %s/client.yaml\n' "$CONF_DIR"
}

# Confirm that the running service owns all configured sockets. A process
# can stay active even if mihomo could not bind one of the listeners.
wait_service_ready() {
  local vless="$1" hy2="$2" anytls="$3" _attempt pid
  for _attempt in {1..10}; do
    pid=$(systemctl show --property MainPID --value "$SERVICE") || pid=0
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] \
      && ss -H -lntp "sport = :$vless" | grep -F "pid=$pid," >/dev/null \
      && ss -H -lnup "sport = :$hy2" | grep -F "pid=$pid," >/dev/null \
      && ss -H -lntp "sport = :$anytls" | grep -F "pid=$pid," >/dev/null \
      && systemctl is-active --quiet "$SERVICE"; then
      return 0
    fi
    sleep 0.5
  done
  warn "mihomo did not open all expected sockets. Check: journalctl -u ${SERVICE} -n 50"
  return 1
}

cleanup_install() {
  local status="$1"
  rm -rf "$install_stage"
  [ "$status" -ne 0 ] || return 0
  warn "Install failed; removing files and proxy rules created by this attempt"
  if [ "$unit_created" -eq 1 ]; then
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  fi
  if [ "$config_created" -eq 1 ] && ! remove_firewall_rules; then
    warn "Firewall cleanup incomplete. Check ufw and run uninstall to retry."
    return
  fi
  if [ "$unit_created" -eq 1 ]; then
    rm -f "$UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [ "$config_created" -eq 1 ]; then rm -rf "$CONF_DIR"; fi
  if [ "$binary_created" -eq 1 ]; then rm -f "$MIHOMO_BIN"; fi
}

cmd_install() (
  case "${1:-}" in
    -h|--help) usage_install; return 0 ;;
  esac
  [ "$#" -eq 0 ] || die "install takes no arguments"
  require_root
  lock_server
  validate_ports
  validate_version "$MIHOMO_VERSION"
  umask 077

  local path ip
  for path in "$CONF_DIR" "$MIHOMO_BIN" "$UNIT_FILE" "$SYSCTL_FILE"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      die "Install would overwrite $path. Inspect the existing installation first."
    fi
  done

  detect_os
  detect_arch
  install_deps curl gzip openssl ufw ca-certificates iproute2 jq
  ip=$(detect_server_ip)
  [[ "$ip" =~ ^[a-fA-F0-9.:]+$ ]] || die "Invalid server IP '$ip'"
  install -d "$(dirname "$MIHOMO_BIN")"

  install_stage=$(mktemp -d "${MIHOMO_BIN}.XXXXXX")
  unit_created=0
  config_created=0
  binary_created=0
  trap 'cleanup_install "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  download_mihomo "$MIHOMO_VERSION" "$install_stage/mihomo"
  gen_credentials "$install_stage/mihomo"
  mkdir -m 700 "$CONF_DIR"
  config_created=1
  gen_cert
  write_server_config
  write_client_artifacts "$ip"
  "$install_stage/mihomo" -t -d "$CONF_DIR" || die "Generated mihomo config failed validation"

  mv "$install_stage/mihomo" "$MIHOMO_BIN"
  binary_created=1
  unit_created=1
  write_systemd
  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
  systemctl start "$SERVICE"
  wait_service_ready "$VLESS_PORT" "$HY2_PORT" "$ANYTLS_PORT" || die "mihomo failed its startup check"
  systemctl enable "$SERVICE" >/dev/null 2>&1
  configure_firewall

  enable_bbr || warn "Could not configure BBR"
  trap - EXIT INT TERM
  rm -rf "$install_stage"
  print_share_links "$ip"
  log "Installed and listening on all three proxy ports"
)

# update

usage_update() {
  cat <<'EOF'
Usage: privnet.sh update [VERSION]

Updates mihomo to the latest release, or to a pinned version
(e.g. privnet.sh update v1.19.10). Config and credentials are kept.
EOF
}

cleanup_update() {
  local status="$1"
  if [ "$status" -ne 0 ] && [ "$update_replaced" -eq 1 ]; then
    warn "Update failed; restoring the previous mihomo binary"
    if ! mv -f "$update_stage/previous" "$MIHOMO_BIN"; then
      warn "Could not restore $MIHOMO_BIN. The backup is at $update_stage/previous."
      return
    fi
    if ! systemctl restart "$SERVICE" || ! wait_service_ready "$vless" "$hy2" "$anytls"; then
      warn "The old binary was restored, but mihomo did not recover. Check the service logs."
    fi
  fi
  rm -rf "$update_stage"
}

cmd_update() (
  case "${1:-}" in
    -h|--help) usage_update; return 0 ;;
  esac
  [ "$#" -le 1 ] || die "update accepts at most one version"
  local ver="${1:-$MIHOMO_VERSION}"
  require_root
  lock_server
  validate_version "$ver"
  [ -x "$MIHOMO_BIN" ] || die "mihomo not found at ${MIHOMO_BIN}. Run 'privnet.sh install' first"

  vless=$(port_from_config vless-reality-in)
  hy2=$(port_from_config hysteria2-in)
  anytls=$(port_from_config anytls-in)
  [ -n "$vless" ] && [ -n "$hy2" ] && [ -n "$anytls" ] || die "Missing listener ports in $CONF_DIR/config.yaml"
  if ! command -v jq >/dev/null || ! command -v ss >/dev/null; then
    install_deps jq iproute2
  fi

  detect_arch
  update_stage=$(mktemp -d "${MIHOMO_BIN}.XXXXXX")
  update_replaced=0
  trap 'cleanup_update "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  download_mihomo "$ver" "$update_stage/mihomo"
  "$update_stage/mihomo" -t -d "$CONF_DIR" || die "The new mihomo cannot load the installed config"
  cp -p "$MIHOMO_BIN" "$update_stage/previous"
  update_replaced=1
  mv -f "$update_stage/mihomo" "$MIHOMO_BIN"
  systemctl restart "$SERVICE"
  wait_service_ready "$vless" "$hy2" "$anytls" || die "Updated service failed its startup check"
  update_replaced=0
  log "Update complete. Current version: $("$MIHOMO_BIN" -v)"
)

# uninstall

usage_uninstall() {
  cat <<'EOF'
Usage: privnet.sh uninstall

Stops and removes the mihomo service, config, binary, sysctl settings and
firewall rules (run as root with sudo).
EOF
}

port_from_config() {
  [ -s "$CONF_DIR/config.yaml" ] || return 0
  awk -v name="$1" '
    /^  - name: / { found = ($3 == name) }
    found && /^    port: / { print $2; exit }
  ' "$CONF_DIR/config.yaml"
}

cmd_uninstall() {
  case "${1:-}" in
    -h|--help) usage_uninstall; return 0 ;;
  esac
  [ "$#" -eq 0 ] || die "uninstall takes no arguments"
  require_root

  lock_server
  if [ ! -s "$CONF_DIR/config.yaml" ] \
      || ! grep -Fxq 'Description=mihomo daemon (proxy server)' "$UNIT_FILE" \
      || ! grep -Fxq "ExecStart=$MIHOMO_BIN -d $CONF_DIR" "$UNIT_FILE"; then
    die "Cannot identify a privnet installation in $CONF_DIR"
  fi
  systemctl stop "$SERVICE"
  systemctl disable "$SERVICE" >/dev/null 2>&1

  if [ -f "$CONF_DIR/firewall.rules" ]; then
    remove_firewall_rules || die "Firewall cleanup incomplete. Retry uninstall after checking ufw."
  else
    warn "Legacy install has no firewall rule record. Inspect ufw and remove obsolete proxy rules manually."
  fi

  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  rm -rf "$CONF_DIR"
  rm -f "$MIHOMO_BIN" "$SYSCTL_FILE"

  log "Uninstall complete."
}

# Subscription

usage_subscription() {
  cat <<'EOF'
Usage: privnet.sh subscription [options] VM[=LABEL][@v4|@v6] ...

Reads client profiles from Azure VMs. Labels default to the uppercased last
part of the VM name, e.g. privnet-jp becomes JP. Nodes dial IPv4 by default.

  -g GROUP             Resource group (default: each VM's name).
  -o OUTPUT            Output file (default: sub.yaml, mode 600).
  -r RULES_FILE        Extra Clash rules (default: rules.txt next to the script).
  -p, --protocols LIST Comma-separated vless, hy2, anytls (default: all).
  -6, --ipv6           Dial IPv6 by default. @v4 or @v6 overrides per VM.
  -h                   Show this help.

Examples:
  privnet.sh subscription -g privnet privnet-jp privnet-sg=SG
  privnet.sh subscription -p vless,anytls privnet-jp@v6 privnet-sg
EOF
}

label_of() {
  printf '%s' "$1" | awk -F- '{print $NF}' | tr '[:lower:]' '[:upper:]'
}

PROTO_KEYS=(vless hy2 anytls)
PROTO_SUFFIXES=(VLESS Hy2 AnyTLS)

set_protocols() {
  local list protocol
  local -a requested=()
  list=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if [ "$list" = all ]; then
    PROTOCOLS="vless hy2 anytls"
    return
  fi
  IFS=$' \t' read -r -a requested <<< "${list//,/ }"
  [ "${#requested[@]}" -gt 0 ] || die "Select at least one protocol: vless, hy2, anytls or all"
  PROTOCOLS=""
  for protocol in "${requested[@]}"; do
    case "$protocol" in
      vless|hy2|anytls) ;;
      *) die "Unknown protocol '$protocol': choose from vless, hy2, anytls or all" ;;
    esac
    case " $PROTOCOLS " in
      *" $protocol "*) ;;
      *) PROTOCOLS="${PROTOCOLS:+$PROTOCOLS }$protocol" ;;
    esac
  done
}

vm_public_ip() {
  local rg="$1" vm="$2" version="$3" nics nic ips ip ids=""
  nics=$(az vm show -g "$rg" -n "$vm" --query 'networkProfile.networkInterfaces[].id' -o tsv) \
    || die "Cannot list NICs for '$vm'"
  while IFS= read -r nic; do
    [ -n "$nic" ] || continue
    ips=$(az network nic show --ids "$nic" \
      --query "ipConfigurations[?privateIPAddressVersion=='$version'].publicIPAddress.id" -o tsv) \
      || die "Cannot inspect NIC '$nic'"
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      [ -z "$ids" ] || die "VM '$vm' has multiple public $version addresses; cannot choose one"
      ids="$ip"
    done <<< "$ips"
  done <<< "$nics"
  [ -n "$ids" ] || die "VM '$vm' has no attached public $version address"
  ip=$(az network public-ip show --ids "$ids" --query ipAddress -o tsv) \
    || die "Cannot read the public $version address for '$vm'"
  case "$version" in
    IPv4) [[ "$ip" =~ ^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$ ]] ;;
    IPv6) [[ "$ip" =~ ^[a-fA-F0-9:]+$ && "$ip" = *:* ]] ;;
  esac || die "VM '$vm' has no allocated public $version address"
  printf '%s\n' "$ip"
}

# Azure can truncate Run Command output. Require both markers before publishing.
proxy_export_script() {
  local family="$1"
  printf 'set -eu\n'
  printf 'echo PRIVNET_PROXIES_BEGIN\n'
  if [ "$family" = v6 ]; then
    cat <<'EOF'
pid=$(systemctl show --property MainPID --value mihomo)
ss -H -6 -lntup | awk -v pid="$pid" '
  index($0, "pid=" pid ",") && $5 !~ /^\[::1\]:/ {
    port = $5
    sub(/^.*:/, "", port)
    print "PRIVNET_V6_PORT", $1, port
  }
'
EOF
  fi
  if [ "$PROTOCOLS" != vless ]; then
    cat <<'EOF'
pin=$(openssl x509 -in /etc/mihomo/server.crt -noout -fingerprint -sha256)
printf 'PRIVNET_CERT %s\n' "$pin" | sed 's/ [^=]*=/ /; s/://g'
EOF
  fi
  cat <<'EOF'
awk '/^proxies:/{f=1; next} /^proxy-groups:/{f=0} f' /etc/mihomo/client.yaml
echo PRIVNET_PROXIES_END
EOF
}

fetch_proxies() {
  local vm="$1" label="$2" family="$3" rg="${RG:-$1}"
  local script result payload ip
  script=$(proxy_export_script "$family")
  result=$(vm_run_command "$rg" "$vm" "$script") \
    || die "Cannot read client configuration from '$vm' (group '$rg')"
  payload=$(remote_stdout <<< "$result")
  ip=$(vm_public_ip "$rg" "$vm" "IPv${family#v}")
  if ! printf '%s\n' "$payload" | awk -v label="$label" -v selected="$PROTOCOLS" -v ip="$ip" -v family="$family" '
    BEGIN {
      keys["\"privnet-vless-reality\""] = "vless"
      keys["\"privnet-hy2\""] = "hy2"
      keys["\"privnet-anytls\""] = "anytls"
      type["vless"] = "vless"
      type["hy2"] = "hysteria2"
      type["anytls"] = "anytls"
      suffix["vless"] = "VLESS"
      suffix["hy2"] = "Hy2"
      suffix["anytls"] = "AnyTLS"
      n = split(selected, protocols, " ")
      for (i = 1; i <= n; i++) wanted[protocols[i]] = 1
    }
    NR == 1 && $0 == "PRIVNET_PROXIES_BEGIN" { begin = 1; next }
    !begin || end { invalid = 1; next }
    $0 == "PRIVNET_PROXIES_END" { check_node(); end = 1; next }
    !kind && /^PRIVNET_CERT / { pin = tolower($2); next }
    !kind && /^PRIVNET_V6_PORT / { v6[$2, $3] = 1; next }
    /^  - name: / {
      check_node()
      kind = keys[$3]
      server = port = auth = proxy_type = public_key = short_id = obfs = obfs_password = ""
      keep = (kind in wanted)
      if (keep) {
        seen[kind]++
        printf "  - name: \"%s-%s\"\n", label, suffix[kind]
        if (kind != "vless") printf "    fingerprint: \"%s\"\n", pin
      }
      next
    }
    !keep || /^[[:space:]]*$/ { next }
    /^    (skip-cert-verify|fingerprint):/ && kind != "vless" { next }
    /^    server: / { server = $2; $0 = "    server: \"" ip "\"" }
    /^    port: / { port = $2 }
    /^    type: / { proxy_type = $2 }
    /^    uuid: / && kind == "vless" { auth = $2 }
    /^    password: / && kind != "vless" { auth = $2 }
    /^      public-key: / { public_key = $2 }
    /^      short-id: / { short_id = $2 }
    /^    obfs: / { obfs = $2 }
    /^    obfs-password: / { obfs_password = $2 }
    { print }
    END {
      if (!end || invalid) exit 1
      if (selected != "vless" && (length(pin) != 64 || pin !~ /^[0-9a-f]+$/)) exit 1
      for (kind in wanted) if (seen[kind] != 1) exit 1
    }
    function present(value) { return value != "" && value != "\"\"" }
    function check_node(transport) {
      if (!keep) return
      transport = (kind == "hy2" ? "udp" : "tcp")
      if (!present(server) || !present(auth) || proxy_type != type[kind] ||
          port !~ /^[1-9][0-9]*$/ || port > 65535 ||
          (kind == "vless" && (!present(public_key) || !present(short_id))) ||
          (kind == "hy2" && present(obfs) && !present(obfs_password)) ||
          (family == "v6" && !v6[transport, port])) invalid = 1
    }
  '; then
    die "Incomplete or unexpected client configuration from '$vm' (group '$rg'). Check the installed protocols and Run Command output."
  fi
}

write_rules() {
  awk -v quote="'" '
    BEGIN { print "rules:" }
    {
      sub(/^[[:space:]]+/, "")
      sub(/^-[[:space:]]+/, "")
      sub(/[[:space:]]+#.*$/, "")
      sub(/[[:space:]]+$/, "")
    }
    /^#/ || /^$/ { next }
    {
      if ($0 == "GEOIP,CN,DIRECT") geoip = 1
      if ($0 ~ /^MATCH,/) catch_all = 1
      gsub(quote, quote quote)
      print "  - " quote $0 quote
    }
    END {
      if (!geoip) print "  - GEOIP,CN,DIRECT"
      if (!catch_all) print "  - MATCH,PROXY"
    }
  ' < "$1"
}

cmd_subscription() (
  local output="sub.yaml" rules_file="" opt
  local default_family="v4" family arg sub_ipv6=false
  local RG="" PROTOCOLS="vless hy2 anytls"
  local -a argv=()
  for arg in "$@"; do
    case "$arg" in
      --ipv6)            argv+=("-6") ;;
      --ipv6=*)          die "--ipv6 takes no value; add @v6 to individual VM specs instead" ;;
      --protocols)       argv+=("-p") ;;
      --protocols=*)     argv+=("-p" "${arg#--protocols=}") ;;
      *)                 argv+=("$arg") ;;
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
  [ -n "$output" ] && [ ! -d "$output" ] || die "Output must be a file path"
  case "$output" in /*) ;; *) output="./$output" ;; esac

  local name label base dup idx suffix failed=0
  local -a names=() labels=() families=() pids=() suffixes=()
  for arg in "$@"; do
    base="${arg%@*}"
    family="$default_family"
    if [ "$base" != "$arg" ]; then family="${arg##*@}"; fi
    case "$family" in
      v4) ;;
      v6) sub_ipv6=true ;;
      *) die "Invalid address family in '$arg': use @v4 or @v6" ;;
    esac
    case "$base" in
      *=*) name="${base%%=*}"; label="${base#*=}" ;;
      *)   name="$base";      label=$(label_of "$name") ;;
    esac
    [ -n "$name" ] || die "Invalid server spec '$arg': empty VM name"
    [[ "$label" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]] \
      || die "Invalid label '$label': use letters, digits, underscores, periods or hyphens"
    names+=("$name")
    labels+=("$label")
    families+=("$family")
  done

  for idx in "${!PROTO_KEYS[@]}"; do
    case " $PROTOCOLS " in
      *" ${PROTO_KEYS[$idx]} "*) suffixes+=("${PROTO_SUFFIXES[$idx]}") ;;
    esac
  done
  local -a identifiers=(PROXY DIRECT REJECT REJECT-DROP PASS COMPATIBLE GLOBAL)
  for label in "${labels[@]}"; do
    identifiers+=("$label")
    for suffix in "${suffixes[@]}"; do identifiers+=("$label-$suffix"); done
  done
  dup=$(printf '%s\n' "${identifiers[@]}" | sort | uniq -d)
  [ -z "$dup" ] || die "Conflicting group or node name(s): $(printf '%s' "$dup" | tr '\n' ' ')"

  if [ -z "$rules_file" ]; then
    rules_file=/dev/null
    if [ -f "$SELF_DIR/rules.txt" ]; then rules_file="$SELF_DIR/rules.txt"; fi
  fi
  [ -r "$rules_file" ] && [ ! -d "$rules_file" ] || die "Cannot read rules file: $rules_file"

  command -v az >/dev/null 2>&1 || die "Azure CLI not found"

  local sub_dir sub_tmp=""
  sub_dir=$(mktemp -d /tmp/privnet-sub.XXXXXX)
  trap 'rm -f "$sub_tmp"; rm -rf "$sub_dir"' EXIT

  # Azure allows one Run Command at a time per VM.
  local repeated
  repeated=$(printf '%s\n' "${names[@]}" | sort -f | uniq -di)
  for idx in "${!names[@]}"; do
    log "Reading ${names[$idx]} (${labels[$idx]}, ${families[$idx]})"
    fetch_proxies "${names[$idx]}" "${labels[$idx]}" "${families[$idx]}" > "$sub_dir/$idx" &
    if [ -n "$repeated" ]; then
      wait "$!" || failed=1
    else
      pids+=("$!")
    fi
  done
  for idx in "${!pids[@]}"; do wait "${pids[$idx]}" || failed=1; done
  [ "$failed" -eq 0 ] || die "Failed to read proxies from one or more VMs"

  sub_tmp=$(mktemp "${output}.XXXXXX") || die "Cannot create a temporary file next to $output"
  {
    write_client_header "$sub_ipv6"
    for idx in "${!names[@]}"; do cat "$sub_dir/$idx"; done

    echo
    echo "proxy-groups:"
    echo '  - name: "PROXY"'
    echo '    type: select'
    echo '    proxies:'
    printf '      - "%s"\n' "${labels[@]}"
    echo '      - DIRECT'
    for label in "${labels[@]}"; do
      printf '\n  - name: "%s"\n    type: select\n    proxies:\n' "$label"
      for suffix in "${suffixes[@]}"; do printf '      - "%s-%s"\n' "$label" "$suffix"; done
    done
    echo
    write_rules "$rules_file"
  } > "$sub_tmp"

  mv -f "$sub_tmp" "$output"
  log "Subscription written to $output (mode 600)"
)

# Azure deploy

usage_deploy() {
  cat <<'EOF'
Usage: privnet.sh deploy -g GROUP -l LOCATION -n NAME [options]

Creates an Azure VM and installs privnet via Run Command.

  -u USER      VM administrator (default: current user).
  -k PUBKEY    Administrator public key (default: ~/.ssh/id_ed25519.pub
               or ~/.ssh/id_rsa.pub).
  -s SIZE      VM size (default: Standard_B2pls_v2).
  -i IMAGE     VM image (default: Debian:debian-12:12-arm64:latest).
  -z ZONE      Availability zone (default: none).
  -t PORT      SSH firewall port (default: 22, must match sshd).
  -v PORT      VLESS port (default: 443).
  -y PORT      Hysteria2 port (default: 8443).
  -a PORT      AnyTLS port (default: 9443).
  -p PREFIX    Enable dual-stack with a GUA IPv6 /48, /52 or /56 prefix.
  -6           Enable dual-stack. Requires -p.
  -h           Show this help.

Environment overrides: VNET_PREFIX, SUBNET_PREFIX, PRIVNET_MIHOMO_VERSION.
EOF
}

make_remote_installer() {
  local wrapper="$1" ip="$2" ipv6_subnet="${3:-}"
  [[ -z "$ipv6_subnet" || "$ipv6_subnet" =~ ^[a-fA-F0-9:]+/64$ ]] || die "Invalid Azure IPv6 subnet"
  {
    cat <<'EOF'
#!/usr/bin/env bash
set -eu
installer=$(mktemp /root/privnet.XXXXXX)
trap 'rm -f "$installer"' EXIT
cat > "$installer" <<'PRIVNET_SCRIPT'
EOF
    cat "$SELF_PATH"
    printf 'PRIVNET_SCRIPT\n'
    # shellcheck disable=SC2016
    printf 'PRIVNET_SSH_PORT=%s PRIVNET_VLESS_PORT=%s PRIVNET_HY2_PORT=%s PRIVNET_ANYTLS_PORT=%s PRIVNET_MIHOMO_VERSION=%s PRIVNET_SERVER_IP=%s PRIVNET_VNET_IPV6_SUBNET=%s PRIVNET_PRINT_LINKS=0 bash "$installer" install\n' \
      "$SSH_PORT" "$VLESS_PORT" "$HY2_PORT" "$ANYTLS_PORT" "$MIHOMO_VERSION" "$ip" "$ipv6_subnet"
    printf "echo PRIVNET_INSTALL_OK\n"
  } > "$wrapper"
}

cmd_deploy() (
  local group="" location="" name="" zone="" opt
  local admin_user="${USER:-azureuser}" ssh_pubkey=""
  local vm_size="Standard_B2pls_v2" image="Debian:debian-12:12-arm64:latest"
  local dual_stack=false ipv6_prefix=""
  local -a vnet_prefixes=("${VNET_PREFIX:-10.0.0.0/16}")
  local -a subnet_prefixes=("${SUBNET_PREFIX:-10.0.0.0/24}")

  while getopts "g:l:n:u:k:K:s:i:z:t:v:y:a:p:6h" opt; do
    case "$opt" in
      g) group="$OPTARG" ;;
      l) location="$OPTARG" ;;
      n) name="$OPTARG" ;;
      u) admin_user="$OPTARG" ;;
      k) ssh_pubkey="$OPTARG" ;;
      K) warn "The -K option is deprecated; deploy uses Azure Run Command for installation" ;;
      s) vm_size="$OPTARG" ;;
      i) image="$OPTARG" ;;
      z) zone="$OPTARG" ;;
      t) SSH_PORT="$OPTARG" ;;
      v) VLESS_PORT="$OPTARG" ;;
      y) HY2_PORT="$OPTARG" ;;
      a) ANYTLS_PORT="$OPTARG" ;;
      6) dual_stack=true ;;
      p) dual_stack=true; ipv6_prefix="$OPTARG" ;;
      h) usage_deploy; return 0 ;;
      *) usage_deploy >&2; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  [ "$#" -eq 0 ] || die "Unexpected deploy argument: $1"
  [ -n "$group" ] && [ -n "$location" ] && [ -n "$name" ] || die "deploy requires -g GROUP -l LOCATION -n NAME"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Invalid resource name '$name'"
  validate_ports
  validate_version "$MIHOMO_VERSION"

  if $dual_stack; then
    case "$ipv6_prefix" in
      *:*/48|*:*/52|*:*/56) ;;
      *) die "Dual-stack deployment requires -p with a /48, /52 or /56 IPv6 prefix" ;;
    esac
    [[ "${ipv6_prefix%/*}" =~ ^[a-fA-F0-9:]+$ ]] || die "Invalid IPv6 prefix"
    vnet_prefixes+=("$ipv6_prefix")
    subnet_prefixes+=("${ipv6_prefix%/*}/64")
  fi

  command -v az >/dev/null 2>&1 || die "Azure CLI not found"

  az account show --output none >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login"

  local candidate
  if [ -z "$ssh_pubkey" ]; then
    for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
      if [ -f "$candidate" ]; then ssh_pubkey="$candidate"; break; fi
    done
  fi
  [ -n "$ssh_pubkey" ] || die "No SSH public key found. Run ssh-keygen -t ed25519 or pass -k PUBKEY."
  [ -f "$ssh_pubkey" ] || die "Public key not found: $ssh_pubkey"

  local exists state resources wrapper=""
  exists=$(az group exists -n "$group" -o json)
  if [ "$exists" = true ]; then
    state=$(az group show -n "$group" --query properties.provisioningState -o tsv)
    [ "$state" != Deleting ] || die "Resource group '$group' is still being deleted. Retry once deletion finishes."
    resources=$(az resource list -g "$group" --query '[].name' -o tsv)
    if grep -Fxiq -e "$name" -e "$name-v6" <<< "$resources"; then
      die "Resources named '$name' or '$name-v6' already exist in '$group'. Choose a different name or inspect those resources."
    fi
  else
    az group create -n "$group" -l "$location" --output none
  fi

  trap '
    status=$?
    rm -f "$wrapper"
    if [ "$status" -ne 0 ]; then
      warn "Deploy failed. Inspect resources for $name in $group before retrying."
    fi
  ' EXIT

  local rule protocol port priority
  log "Creating NSG $name"
  az network nsg create -g "$group" -n "$name" -l "$location" --output none
  while read -r rule protocol port priority; do
    az network nsg rule create -g "$group" --nsg-name "$name" -n "$rule" \
      --priority "$priority" --direction Inbound --access Allow --protocol "$protocol" \
      --source-address-prefixes '*' --source-port-ranges '*' \
      --destination-address-prefixes '*' --destination-port-ranges "$port" --output none </dev/null
  done <<EOF
SSH Tcp $SSH_PORT 300
VLESS-Reality Tcp $VLESS_PORT 310
Hysteria2 Udp $HY2_PORT 320
AnyTLS Tcp $ANYTLS_PORT 330
EOF

  log "Creating VNet $name"
  az network vnet create -g "$group" -n "$name" -l "$location" \
    --address-prefixes "${vnet_prefixes[@]}" --subnet-name default \
    --subnet-prefixes "${subnet_prefixes[@]}" --output none

  local -a ip_options=(-g "$group" -l "$location" --sku Standard --allocation-method Static --output none)
  local -a vm_options=(-g "$group" -n "$name" --location "$location" --nics "$name"
    --image "$image" --size "$vm_size" --os-disk-name "$name"
    --admin-username "$admin_user" --ssh-key-values "$ssh_pubkey" --output none)
  if [ -n "$zone" ]; then
    ip_options+=(--zone "$zone")
    vm_options+=(--zone "$zone")
  fi

  log "Creating static public IPs"
  az network public-ip create -n "$name" "${ip_options[@]}"
  if $dual_stack; then
    az network public-ip create -n "$name-v6" --version IPv6 "${ip_options[@]}"
  fi

  log "Creating NIC $name"
  az network nic create -g "$group" -n "$name" -l "$location" \
    --vnet-name "$name" --subnet default \
    --network-security-group "$name" --public-ip-address "$name" \
    --accelerated-networking true --output none
  if $dual_stack; then
    az network nic ip-config create -g "$group" --nic-name "$name" -n ipconfig2 \
      --private-ip-address-version IPv6 --vnet-name "$name" --subnet default \
      --public-ip-address "$name-v6" --output none
  fi

  log "Creating VM $name"
  az vm create "${vm_options[@]}"

  local ip result
  ip=$(az network public-ip show -g "$group" -n "$name" --query ipAddress -o tsv)
  [[ "$ip" =~ ^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$ ]] || die "Failed to get public IPv4 address for $name"
  log "$name public IP: $ip"

  log "Installing on $name via Azure Run Command"
  wrapper=$(mktemp /tmp/privnet-wrapper.XXXXXX)
  make_remote_installer "$wrapper" "$ip" "${subnet_prefixes[1]-}"
  result=$(vm_run_command "$group" "$name" "@$wrapper") || die "Azure Run Command failed on $name"
  if ! remote_stdout <<< "$result" | grep -Fx PRIVNET_INSTALL_OK >/dev/null; then
    printf '%s\n' "$result" >&2
    die "The installer did not confirm success on $name"
  fi

  log "Deployment complete. Generate the client configuration:"
  printf '  bash %q subscription -g %q %q\n' "$SELF_PATH" "$group" "$name" >&2
)

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
    deploy|install|update|uninstall|subscription)
      TAG="$cmd"
      "cmd_$cmd" "$@"
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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
