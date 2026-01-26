#!/usr/bin/env bash
# ssh-config.sh — reliable SSH hardening (port + key auth)
#
# Interactive:
#   sudo ./ssh-config.sh
#
# Key auth only:
#   sudo ./ssh-config.sh -k "ssh-ed25519 AAAA..."
#   echo "ssh-ed25519 AAAA..." | sudo ./ssh-config.sh -k
#
# Key + port (non-interactive, for curl|bash):
#   KEY="ssh-ed25519 AAAA..."
#   curl -fsSL "URL?v=$(date +%s)" | sudo bash -s -- -k "$KEY" --random-port --yes
#   curl -fsSL "URL?v=$(date +%s)" | sudo bash -s -- -k "$KEY" --port 22222 --yes

set -euo pipefail

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_D_DIR="/etc/ssh/sshd_config.d"
DROPIN="${SSHD_D_DIR}/99-custom.conf"
PORT_MARKER="/etc/ssh/.custom_port"
MIN_PORT=10000
MAX_PORT=65000

# managed defaults (avoid “magic numbers”)
MAX_AUTH_TRIES_DEFAULT="6"
MAX_SESSIONS_DEFAULT="4"
MAX_STARTUPS_DEFAULT="10:30:60"

ok()   { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"; }
is_root() { [[ "${EUID}" -eq 0 ]]; }
has_tty() { [[ -r /dev/tty ]]; }

sshd_bin() {
  if command -v sshd >/dev/null 2>&1; then echo "sshd"; return; fi
  [[ -x /usr/sbin/sshd ]] && echo "/usr/sbin/sshd" && return
  die "sshd binary not found"
}

svc_name() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "sshd.service" && { echo "sshd"; return; }
    systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "ssh.service"  && { echo "ssh";  return; }
  fi
  echo ""
}

restart_ssh() {
  local svc; svc="$(svc_name)"
  info "Restarting SSH..."
  if [[ -n "$svc" ]]; then
    systemctl restart "${svc}.service"
    ok "SSH restarted (${svc}.service)"
    return
  fi
  service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || die "Failed to restart SSH (no systemd service found)."
  ok "SSH restarted (service)"
}

disable_socket_activation() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    info "Disabling ssh.socket (socket activation)..."
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    ok "ssh.socket disabled"
  fi
}

mk_backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -f "$f" "${f}.bak.${ts}"
  ok "Backup: ${f}.bak.${ts}"
}

write_atomic() {
  local dst="$1"
  local tmp; tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod 0644 "$tmp" || true
  mv -f "$tmp" "$dst"
}

test_sshd() {
  local sshd; sshd="$(sshd_bin)"
  "$sshd" -t >/dev/null 2>&1
}

apply_dropin() {
  local content="$1"
  mkdir -p "$SSHD_D_DIR"
  mk_backup "$DROPIN"
  write_atomic "$DROPIN" <<<"$content"
  ok "Wrote drop-in: $DROPIN"
}

apply_mainfile_block() {
  local content="$1"
  mk_backup "$SSHD_MAIN"

  # Remove keys we manage (commented or not), then append.
  # NOTE: avoid \+ / ERE; keep it portable.
  local keys=(
    "Port" "MaxAuthTries" "MaxSessions" "MaxStartups"
    "PubkeyAuthentication" "PasswordAuthentication" "KbdInteractiveAuthentication" "ChallengeResponseAuthentication"
  )
  for k in "${keys[@]}"; do
    sed -i "/^[#[:space:]]*${k}[[:space:]]/d" "$SSHD_MAIN"
  done

  printf "\n# Managed by ssh-config.sh\n%s\n" "$content" >>"$SSHD_MAIN"
  ok "Updated: $SSHD_MAIN"
}

apply_config_safely() {
  local content="$1"

  if [[ -d "$SSHD_D_DIR" ]]; then
    local old_exists="false"
    [[ -f "$DROPIN" ]] && old_exists="true"

    apply_dropin "$content"

    if test_sshd; then
      ok "sshd config test OK"
      return 0
    fi

    warn "sshd config test failed after drop-in. Rolling back."
    if [[ "$old_exists" == "true" ]]; then
      local last; last="$(ls -1t "${DROPIN}.bak."* 2>/dev/null | head -1 || true)"
      [[ -n "$last" ]] && cp -f "$last" "$DROPIN" || rm -f "$DROPIN"
    else
      rm -f "$DROPIN"
    fi
    die "Invalid sshd config after writing $DROPIN. Run: $(sshd_bin) -t and inspect $DROPIN / $SSHD_MAIN."
  fi

  apply_mainfile_block "$content"

  if test_sshd; then
    ok "sshd config test OK"
    return 0
  fi

  warn "sshd config test failed after editing main config. Rolling back."
  local last; last="$(ls -1t "${SSHD_MAIN}.bak."* 2>/dev/null | head -1 || true)"
  [[ -n "$last" ]] && cp -f "$last" "$SSHD_MAIN"
  die "Invalid sshd config after editing $SSHD_MAIN. Run: $(sshd_bin) -t and inspect $SSHD_MAIN."
}

# ---- robust interactive input (never exits on invalid input / EOF) ----
read_tty() {
  local __var="$1" __prompt="$2" __tmp=""
  if has_tty; then
    if ! IFS= read -r -p "$__prompt" __tmp </dev/tty; then
      return 1
    fi
  else
    return 1
  fi
  printf -v "$__var" '%s' "$__tmp"
  return 0
}

prompt_yn() {
  local msg="$1" def="${2:-y}" ans
  while true; do
    if ! read_tty ans "${msg} [y/n] (default: ${def}): "; then
      warn "No TTY for prompt: '${msg}'. Use --yes for non-interactive runs."
      return 1
    fi

    ans="${ans:-$def}"
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    case "$ans" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Invalid input: '$ans'. Enter y or n." ;;
    esac
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( $1 >= 1024 && $1 <= 65535 )) || return 1
  return 0
}

port_in_use() {
  local p="$1"

  # Best: ss filter (precise). Fallback: parse.
  if command -v ss >/dev/null 2>&1; then
    if ss -H -ltn "sport = :$p" >/dev/null 2>&1; then
      ss -H -ltn "sport = :$p" | grep -q .
      return $?
    fi
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${p}$"
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${p}$"
    return $?
  fi

  return 1
}

rand_port() {
  local tries=0 max=120 p
  while (( tries < max )); do
    if command -v shuf >/dev/null 2>&1; then
      p="$(shuf -i "${MIN_PORT}-${MAX_PORT}" -n 1)"
    else
      p=$(( (RANDOM % (MAX_PORT - MIN_PORT + 1)) + MIN_PORT ))
    fi
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
    ((tries++))
  done
  die "Failed to find free port after $max tries"
}

prompt_port() {
  local p
  while true; do
    if ! read_tty p "Enter SSH port (1024-65535): "; then
      warn "No TTY for port prompt. Use --port / --random-port for non-interactive runs."
      return 1
    fi

    p="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ -z "$p" ]]; then
      warn "Port cannot be empty."
      continue
    fi

    if ! valid_port "$p"; then
      warn "Invalid port: '$p'. Must be a number between 1024 and 65535."
      continue
    fi

    if port_in_use "$p"; then
      warn "Port $p is in use."
      continue
    fi

    echo "$p"
    return 0
  done
}

configure_firewall() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "UFW: allowing ${port}/tcp"
    ufw allow "${port}/tcp" comment "SSH" >/dev/null 2>&1 || die "UFW failed"
    ok "UFW updated"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    info "firewalld: allowing ${port}/tcp"
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || die "firewalld failed"
    firewall-cmd --reload >/dev/null 2>&1 || die "firewalld reload failed"
    ok "firewalld updated"
  fi

  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    if ! command -v semanage >/dev/null 2>&1; then
      warn "SELinux is Enforcing, but 'semanage' is missing. SSH may FAIL on new port."
      warn "Install: dnf/yum install -y policycoreutils-python-utils"
    else
      info "SELinux: allowing ssh_port_t on ${port}/tcp"
      semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || \
      semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null || true
      ok "SELinux updated (if needed)"
    fi
  fi
}

verify_listening() {
  local port="$1" i
  for i in {1..10}; do
    sleep 1
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${port}$" && return 0
    fi
  done
  return 1
}

# ---- key handling ----
current_user() { [[ -n "${SUDO_USER:-}" ]] && echo "$SUDO_USER" || echo "$USER"; }
current_home() { [[ -n "${SUDO_USER:-}" ]] && eval echo "~$SUDO_USER" || echo "$HOME"; }

read_key() {
  local key=""
  if [[ -n "${1:-}" ]]; then
    key="$1"
  else
    key="$(cat || true)"
  fi

  key="$(echo "$key" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  key="$(echo "$key" | grep -v '^[[:space:]]*$' | head -1 || true)"
  [[ -n "$key" ]] || die "No SSH public key provided"
  echo "$key"
}

valid_key() {
  local k="$1"
  [[ "$k" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-dss)[[:space:]]+[A-Za-z0-9+/=]+ ]] && return 0
  if command -v ssh-keygen >/dev/null 2>&1; then
    echo "$k" | ssh-keygen -l -f - >/dev/null 2>&1 && return 0
  fi
  return 1
}

ensure_ssh_dir() {
  local home="$1" user="$2"
  local dir="${home}/.ssh"
  mkdir -p "$dir"
  chmod 700 "$dir"
  chown "$user:$user" "$dir" 2>/dev/null || true
}

add_authorized_key() {
  local key="$1" home="$2" user="$3"
  local ak="${home}/.ssh/authorized_keys"
  touch "$ak"
  chmod 600 "$ak"
  chown "$user:$user" "$ak" 2>/dev/null || true

  if grep -Fxq "$key" "$ak" 2>/dev/null; then
    warn "Key already present in authorized_keys"
    return 1
  fi

  mk_backup "$ak"
  echo "$key" >>"$ak"
  ok "Key added to ${ak}"
  return 0
}

usage() {
  cat <<EOF
Usage:
  sudo $0
  sudo $0 -k [KEY]
  sudo $0 --port N [--yes]
  sudo $0 --random-port [--yes]
  sudo $0 -k [KEY] --port N --yes
  sudo $0 -k [KEY] --random-port --yes

Options:
  -k, --key [KEY]     Add SSH public key (if KEY omitted, read from stdin)
  --port N            Set SSH port non-interactively
  --random-port       Pick random free port non-interactively
  -y, --yes           Skip confirmations (recommended for curl|bash)
  -h, --help          Show help

EOF
}

main() {
  is_root || die "Run as root (sudo)."

  need sed
  need awk
  need grep
  need date
  need mktemp
  sshd_bin >/dev/null

  [[ -f "$SSHD_MAIN" ]] || die "SSH config not found: $SSHD_MAIN"

  local key_mode="false"
  local key_arg=""
  local assume_yes="false"
  local port_mode="none"   # none|manual|random|interactive
  local port_value=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -k|--key)
        key_mode="true"
        shift || true
        if [[ $# -gt 0 && "${1:-}" != "-"* ]]; then
          key_arg="$1"
          shift || true
        fi
        ;;
      --port)
        shift || true
        [[ $# -gt 0 ]] || die "--port requires a value"
        port_mode="manual"
        port_value="$1"
        shift || true
        ;;
      --random-port)
        port_mode="random"
        shift || true
        ;;
      -y|--yes)
        assume_yes="true"
        shift || true
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  # ---- key auth path (can be combined with port flags) ----
  if [[ "$key_mode" == "true" ]]; then
    local u h k
    u="$(current_user)"
    h="$(current_home)"
    [[ -d "$h" ]] || die "Cannot determine home directory for user: $u"

    k="$(read_key "${key_arg:-}")"
    valid_key "$k" || die "Invalid SSH key format"

    info "Target user: $u"
    ensure_ssh_dir "$h" "$u"

    # Do NOT exit if key already exists; continue (may apply port/other settings).
    add_authorized_key "$k" "$h" "$u" || true

    local auth_block
    auth_block=$(
      cat <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
    )

    apply_config_safely "$auth_block"
  fi

  # ---- port path ----
  local do_port="false"
  local new_port=""

  if [[ "$port_mode" == "manual" ]]; then
    do_port="true"
    valid_port "$port_value" || die "Invalid --port '$port_value' (must be 1024-65535)"
    port_in_use "$port_value" && die "Port $port_value is in use"
    new_port="$port_value"
  elif [[ "$port_mode" == "random" ]]; then
    do_port="true"
    new_port="$(rand_port)"
    ok "Generated port: $new_port"
  else
    # No explicit port flags:
    # - if key_mode only: default to NOT touching port (safer)
    # - if no key_mode: default to interactive port change
    if [[ "$key_mode" == "false" ]]; then
      do_port="true"
      port_mode="interactive"
    fi
  fi

  if [[ "$do_port" == "true" && "$port_mode" == "interactive" ]]; then
    has_tty || die "No TTY available for interactive port. Use --port / --random-port (and optionally --yes)."

    echo
    info "SSH port change mode"
    if prompt_yn "Generate random port?" "y"; then
      new_port="$(rand_port)"
      ok "Generated port: $new_port"
    else
      new_port="$(prompt_port)" || die "Port prompt failed."
      ok "Selected port: $new_port"
    fi
  fi

  if [[ "$do_port" == "true" ]]; then
    if [[ "$assume_yes" != "true" && "$port_mode" != "random" ]]; then
      has_tty || die "No TTY for confirmation. Use --yes for non-interactive runs."
      echo
      info "Will apply:"
      echo "  Port         ${new_port}"
      echo "  MaxAuthTries  ${MAX_AUTH_TRIES_DEFAULT}"
      echo "  MaxSessions   ${MAX_SESSIONS_DEFAULT}"
      echo "  MaxStartups   ${MAX_STARTUPS_DEFAULT}"
      echo
      prompt_yn "Continue?" "y" || { echo "Cancelled"; exit 0; }
    fi

    configure_firewall "$new_port"

    local port_block
    port_block=$(
      cat <<EOF
Port ${new_port}
MaxAuthTries ${MAX_AUTH_TRIES_DEFAULT}
MaxSessions ${MAX_SESSIONS_DEFAULT}
MaxStartups ${MAX_STARTUPS_DEFAULT}
EOF
    )

    apply_config_safely "$port_block"
    echo "$new_port" >"$PORT_MARKER" || true
  fi

  # If nothing requested, show help-ish message
  if [[ "$key_mode" == "false" && "$do_port" == "false" ]]; then
    warn "No action requested. Use -k/--key, --port N, or --random-port (and optionally --yes)."
    usage
    exit 1
  fi

  disable_socket_activation
  restart_ssh

  if [[ "$do_port" == "true" ]]; then
    if verify_listening "$new_port"; then
      ok "SSH is listening on port $new_port"
    else
      warn "Could not verify listening on $new_port (check: ss -tln | grep :$new_port)"
    fi
    echo
    warn "IMPORTANT: keep this session open. Test in a new terminal:"
    echo "  ssh -p $new_port user@host"
  else
    echo
    ok "Auth settings applied."
    warn "IMPORTANT: test SSH in a NEW session before closing this one."
  fi
}

main "$@"
