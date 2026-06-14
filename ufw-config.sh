#!/usr/bin/env bash
# ufw-config.sh — configure UFW firewall with selectable options
#
# Usage:
#   sudo ./ufw-config.sh
#   sudo ./ufw-config.sh --yes
#   sudo ./ufw-config.sh --ssh-port 22222 --no-xray --extra-ports 8080,9000-9002 --yes
#   curl -sSL "URL?v=$(date +%s)" | sudo bash -s -- --yes

set -euo pipefail

SCRIPTS_RAW_BASE="${SCRIPTS_RAW_BASE:-https://raw.githubusercontent.com/WEBzaytsev/scripts/main}"

_bootstrap_lib() {
  [[ -n "${SCRIPTS_COMMON_LOADED:-}" ]] && return 0
  local lib=""
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/fd/"* && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/common.sh"
  fi
  if [[ -n "$lib" && -f "$lib" ]]; then
    # shellcheck source=lib/common.sh
    source "$lib"
  else
    local tmp; tmp="$(mktemp)"
    curl -fsSL "${SCRIPTS_RAW_BASE}/lib/common.sh?v=$(date +%s)" -o "$tmp" \
      || { echo "[ERROR] Failed to fetch lib/common.sh" >&2; rm -f "$tmp"; exit 1; }
    source "$tmp"
    rm -f "$tmp"
  fi
}

_bootstrap_lib

# ---------- ufw helpers ----------

ufw_allow() {
  local rule="$1" comment="${2:-}"
  if ufw status 2>/dev/null | grep -q "ALLOW" && ufw status 2>/dev/null | grep "ALLOW" | grep -qF "${rule}"; then
    ok "Already allowed: $rule (skipped)"
    return
  fi
  if [[ -n "$comment" ]]; then
    ufw allow "$rule" comment "$comment" >/dev/null 2>&1
  else
    ufw allow "$rule" >/dev/null 2>&1
  fi
  ok "Allowed $rule"
}

# ---------- port detection helpers ----------

_xray_ports_from_json() {
  local f="$1"
  [[ -f "$f" ]] || return
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.inbounds // [])[].port | select(. != null) | if type == "number" then tostring else . end' "$f" 2>/dev/null
  else
    grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+'
    grep -oE '"port"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$f" 2>/dev/null | grep -oE '"[0-9][^"]*"' | tr -d '"'
  fi
}

_expand_port_spec() {
  local spec="$1" part a b
  for part in ${spec//,/ }; do
    if [[ "$part" == *-* ]]; then
      a="${part%-*}"; b="${part#*-}"
      [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || continue
      for (( p=a; p<=b; p++ )); do echo "$p"; done
    else
      [[ "$part" =~ ^[0-9]+$ ]] && echo "$part"
    fi
  done
}

parse_extra_ports() {
  local spec="$1"
  local p
  [[ -n "$spec" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] && echo "$p"
  done < <(_expand_port_spec "$spec")
}

detect_ssh_port() {
  local port=""
  [[ -f /etc/ssh/.custom_port ]] && port="$(cat /etc/ssh/.custom_port 2>/dev/null)"
  if [[ -z "$port" ]]; then
    port="$(grep -E "^Port[[:space:]]" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)"
  fi
  if [[ -z "$port" ]]; then
    port="$(ss -tlnp 2>/dev/null | grep -E "sshd|\"ssh\"" | grep -oE ':([0-9]+)' | head -1 | tr -d ':')"
  fi
  echo "${port:-22}"
}

detect_xray_ports() {
  local ssh_port="$1"
  local remnawave_port="${2:-}"
  local ports=()

  for cfg in "/etc/xray/config.json" "/usr/local/etc/xray/config.json"; do
    [[ -f "$cfg" ]] || continue
    while IFS= read -r spec; do
      [[ -z "$spec" ]] && continue
      while IFS= read -r p; do
        [[ -n "$p" ]] && ports+=("$p")
      done < <(_expand_port_spec "$spec")
    done < <(_xray_ports_from_json "$cfg")
    [[ ${#ports[@]} -gt 0 ]] && break
  done

  local remnawave_paths=("/opt/remnanode/.env" "/opt/remnawave/.env")
  while IFS= read -r env_file; do
    [[ -f "$env_file" ]] || continue
    local is_remnawave=false
    for rp in "${remnawave_paths[@]}"; do [[ "$env_file" == "$rp" ]] && { is_remnawave=true; break; }; done
    "$is_remnawave" && continue
    grep -qE "^(XTLS_API_PORT|SELF_STEAL_PORT)=" "$env_file" 2>/dev/null || continue
    if grep -qE "^XTLS_API_PORT=" "$env_file" 2>/dev/null; then
      local p; p="$(grep -E "^NODE_PORT=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')"
      [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
    fi
    local p; p="$(grep -E "^SELF_STEAL_PORT=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')"
    [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
  done < <(find /opt /root /etc /usr/local -maxdepth 3 -name ".env" -type f 2>/dev/null)

  if command -v docker >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name="${line%% *}" rest="${line#* }"
      if [[ "$name" =~ [xX]ray ]] || [[ "$rest" =~ [xX]ray ]] || [[ "$rest" =~ [vV]2ray ]]; then
        while IFS= read -r p; do
          [[ -n "$p" ]] && ports+=("$p")
        done < <(docker port "$name" 2>/dev/null | grep -oE ':[0-9]+$' | tr -d ':')
      fi
    done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null)
  fi

  local uniq=()
  for p in "${ports[@]}"; do
    [[ "$p" == "22" || "$p" == "$ssh_port" || "$p" == "443" ]] && continue
    [[ -n "$remnawave_port" && "$p" == "$remnawave_port" ]] && continue
    local skip=false
    for u in "${uniq[@]}"; do [[ "$u" == "$p" ]] && { skip=true; break; }; done
    [[ "$skip" == false ]] && uniq+=("$p")
  done

  echo "${uniq[*]:-}"
}

detect_remnawave() {
  local remnawave_paths=("/opt/remnanode/.env" "/opt/remnawave/.env")
  local port="" extra=()
  for env_file in "${remnawave_paths[@]}"; do
    [[ -f "$env_file" ]] || continue
    if [[ -z "$port" ]]; then
      local p; p="$(grep -E "^NODE_PORT=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')"
      [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && port="$p"
    fi
    local p; p="$(grep -E "^SELF_STEAL_PORT=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')"
    [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && extra+=("$p")
  done
  echo "${port:-}|${extra[*]:-}"
}

detect_openvpn() {
  command -v openvpn >/dev/null 2>&1 || (has_systemd && systemctl list-units --type=service 2>/dev/null | grep -q openvpn)
}

# ---------- apply helpers ----------

apply_ssh_rule() {
  local ssh_port="$1"
  info "Allowing SSH..."
  if [[ "$ssh_port" == "22" ]]; then
    ufw_allow "OpenSSH"
  else
    ufw_allow "$ssh_port/tcp" "SSH"
  fi
}

apply_https_rule() {
  info "Allowing HTTPS/VPN..."
  ufw_allow "443/tcp" "HTTPS/VPN"
}

apply_xray_rules() {
  local -a xray_ports=("$@")
  [[ ${#xray_ports[@]} -gt 0 ]] || return 0
  info "Allowing Xray ports..."
  local p
  for p in "${xray_ports[@]}"; do
    ufw_allow "$p/tcp" "Xray"
    ufw_allow "$p/udp" "Xray"
  done
}

apply_remnawave_rules() {
  local remnawave_port="$1"
  local remnawave_extra="$2"
  [[ -n "$remnawave_port" ]] || return 0
  info "Allowing Remnawave API..."
  ufw_allow "$remnawave_port/tcp" "Remnawave API"
  local p
  for p in $remnawave_extra; do
    ufw_allow "$p/tcp" "Remnawave"
  done
}

apply_openvpn_rule() {
  info "Allowing OpenVPN..."
  ufw_allow "1194/udp" "OpenVPN"
}

apply_extra_port_rules() {
  local -a extra_ports=("$@")
  [[ ${#extra_ports[@]} -gt 0 ]] || return 0
  info "Allowing extra ports..."
  local p
  for p in "${extra_ports[@]}"; do
    ufw_allow "$p/tcp" "Extra"
    ufw_allow "$p/udp" "Extra"
  done
}

apply_icmp_block() {
  info "Configuring ICMP blocking..."
  local before_rules="/etc/ufw/before.rules"
  if [[ ! -f "$before_rules" ]]; then
    warn "$before_rules not found; skipping ICMP configuration"
    return 0
  fi

  local icmp_needs_change=false
  grep -q "icmp.*-j ACCEPT" "$before_rules" && icmp_needs_change=true
  grep -q "icmp-type source-quench" "$before_rules" || icmp_needs_change=true

  if [[ "$icmp_needs_change" == true ]]; then
    mk_backup "$before_rules"
    local icmp_types=(destination-unreachable time-exceeded parameter-problem echo-request)
    for icmp_type in "${icmp_types[@]}"; do
      sed -i "s/-A ufw-before-input -p icmp --icmp-type ${icmp_type} -j ACCEPT/-A ufw-before-input -p icmp --icmp-type ${icmp_type} -j DROP/g" "$before_rules"
      sed -i "s/-A ufw-before-forward -p icmp --icmp-type ${icmp_type} -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type ${icmp_type} -j DROP/g" "$before_rules"
    done
    if ! grep -q "icmp-type source-quench" "$before_rules"; then
      sed -i '/-A ufw-before-input -p icmp --icmp-type echo-request/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$before_rules"
    fi
    ok "ICMP rules set to DROP"
  else
    ok "ICMP already configured (skipped)"
  fi
}

# ---------- usage ----------

usage() {
  cat <<EOF
Usage:
  sudo $0 [OPTIONS]

Options:
  --ssh-port N       Override SSH port (default: auto-detect)
  --no-https         Do not allow 443/tcp
  --no-xray          Skip Xray port auto-detection
  --no-remnawave     Skip Remnawave port auto-detection
  --no-openvpn       Skip OpenVPN auto-detection
  --no-icmp-block    Do not modify ICMP rules
  --extra-ports SPEC Extra ports to allow (comma-separated or ranges, tcp+udp)
  -y, --yes          Skip confirmations
  -h, --help         Show help
EOF
}

# ---------- main ----------

main() {
  is_root || die "Run as root (sudo)."
  need sed; need grep; need ss; need awk

  local assume_yes="false"
  local ssh_port_override=""
  local do_https="true"
  local do_xray="auto"
  local do_remnawave="auto"
  local do_openvpn="auto"
  local do_icmp="true"
  local extra_ports_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-port)
        shift || true
        [[ $# -gt 0 ]] || die "--ssh-port requires a value"
        ssh_port_override="$1"
        shift || true
        ;;
      --no-https) do_https="false"; shift ;;
      --no-xray) do_xray="false"; shift ;;
      --no-remnawave) do_remnawave="false"; shift ;;
      --no-openvpn) do_openvpn="false"; shift ;;
      --no-icmp-block) do_icmp="false"; shift ;;
      --extra-ports)
        shift || true
        [[ $# -gt 0 ]] || die "--extra-ports requires a value"
        extra_ports_arg="$1"
        shift || true
        ;;
      -y|--yes) assume_yes="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW not installed. Installing..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null 2>&1 && apt-get install -y ufw >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y ufw >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y ufw >/dev/null 2>&1
    else
      die "Cannot install UFW: unknown package manager"
    fi
    ok "UFW installed"
  fi

  echo ""
  info "UFW Firewall Configuration"
  echo ""

  # --- Resolve SSH port ---
  local ssh_port
  if [[ -n "$ssh_port_override" ]]; then
    [[ "$ssh_port_override" =~ ^[0-9]+$ ]] && (( ssh_port_override >= 1 && ssh_port_override <= 65535 )) \
      || die "Invalid --ssh-port '$ssh_port_override' (must be 1-65535)"
    ssh_port="$ssh_port_override"
    info "SSH port: $ssh_port (override)"
  else
    ssh_port="$(detect_ssh_port)"
    info "SSH port: $ssh_port (auto-detected)"
  fi

  # --- Resolve optional services ---
  local remnawave_port="" remnawave_extra=""
  if [[ "$do_remnawave" == "auto" ]]; then
    local remnawave_info; remnawave_info="$(detect_remnawave)"
    remnawave_port="${remnawave_info%%|*}"
    remnawave_extra="${remnawave_info#*|}"
    [[ -n "$remnawave_port" ]] && info "Remnawave port: $remnawave_port"
  fi

  local openvpn_installed=false
  if [[ "$do_openvpn" == "auto" ]] && detect_openvpn; then
    openvpn_installed=true
    info "OpenVPN: detected"
  fi

  local -a xray_ports=()
  if [[ "$do_xray" == "auto" ]]; then
    local xray_ports_str; xray_ports_str="$(detect_xray_ports "$ssh_port" "$remnawave_port")"
    read -r -a xray_ports <<< "$xray_ports_str"
    [[ ${#xray_ports[@]} -gt 0 ]] && info "Xray ports: ${xray_ports[*]}"
  fi

  local -a extra_ports=()
  if [[ -n "$extra_ports_arg" ]]; then
    while IFS= read -r p; do
      [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) \
        || die "Invalid port in --extra-ports: '$p'"
      extra_ports+=("$p")
    done < <(parse_extra_ports "$extra_ports_arg")
    [[ ${#extra_ports[@]} -gt 0 ]] && info "Extra ports: ${extra_ports[*]}"
  fi

  # --- Summary ---
  echo ""
  info "Will configure:"
  echo "  [x] Allow SSH on port $ssh_port"
  if [[ "$do_https" == "true" ]]; then
    echo "  [x] Allow 443/tcp (HTTPS/VPN)"
  else
    echo "  [ ] HTTPS/VPN: disabled"
  fi
  if [[ "$do_xray" == "auto" ]]; then
    if [[ ${#xray_ports[@]} -gt 0 ]]; then
      echo "  [x] Allow Xray: ${xray_ports[*]} (detected)"
    else
      echo "  [ ] Xray: not detected"
    fi
  else
    echo "  [ ] Xray: disabled"
  fi
  if [[ "$do_remnawave" == "auto" ]]; then
    if [[ -n "$remnawave_port" ]]; then
      local extra_str=""
      [[ -n "$remnawave_extra" ]] && extra_str=" + $remnawave_extra"
      echo "  [x] Allow Remnawave: ${remnawave_port}/tcp${extra_str} (detected)"
    else
      echo "  [ ] Remnawave: not detected"
    fi
  else
    echo "  [ ] Remnawave: disabled"
  fi
  if [[ "$do_openvpn" == "auto" ]]; then
    if $openvpn_installed; then
      echo "  [x] Allow OpenVPN: 1194/udp (detected)"
    else
      echo "  [ ] OpenVPN: not detected"
    fi
  else
    echo "  [ ] OpenVPN: disabled"
  fi
  if [[ ${#extra_ports[@]} -gt 0 ]]; then
    echo "  [x] Allow extra ports: ${extra_ports[*]}"
  fi
  if [[ "$do_icmp" == "true" ]]; then
    echo "  [x] Block ICMP ping requests"
  else
    echo "  [ ] ICMP block: disabled"
  fi
  echo ""

  if [[ "$assume_yes" != "true" ]]; then
    has_tty || die "No TTY for confirmation. Use --yes."
    prompt_yn "Continue?" "y" || { echo "Cancelled"; exit 0; }
  fi

  echo ""
  info "Setting default policies..."
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ok "Default policies set"

  apply_ssh_rule "$ssh_port"

  if [[ "$do_https" == "true" ]]; then
    apply_https_rule
  fi

  if [[ "$do_xray" == "auto" ]]; then
    apply_xray_rules "${xray_ports[@]}"
  fi

  if [[ "$do_remnawave" == "auto" ]]; then
    apply_remnawave_rules "$remnawave_port" "$remnawave_extra"
  fi

  if [[ "$do_openvpn" == "auto" ]] && $openvpn_installed; then
    apply_openvpn_rule
  fi

  apply_extra_port_rules "${extra_ports[@]}"

  if [[ "$do_icmp" == "true" ]]; then
    echo ""
    apply_icmp_block
  fi

  echo ""
  info "Enabling UFW..."
  ufw --force enable >/dev/null 2>&1
  ok "UFW enabled"

  echo ""
  info "Current UFW status:"
  ufw status verbose

  echo ""
  if ufw status | grep -qE "$ssh_port/tcp|OpenSSH"; then
    ok "SSH port $ssh_port is allowed"
  else
    warn "SSH port might not be allowed! Check: ufw status"
  fi

  echo ""
  ok "UFW configured successfully."
  echo ""
  warn "IMPORTANT: Keep this session open!"
  warn "Test new SSH connection before closing."
  echo ""
}

main "$@"
