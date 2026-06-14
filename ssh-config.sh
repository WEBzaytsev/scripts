#!/usr/bin/env bash
# ssh-config.sh — robust SSH hardening (systemd service or socket activation)
# - add SSH public key (optional)
# - disable password auth (optional when -k)
# - change SSH port (service mode via sshd_config, socket mode via systemd socket drop-in)
#
# Examples:
#   curl -fsSL URL | sudo bash -s -- -k "ssh-ed25519 AAAA..." --random-port --yes
#   sudo ./ssh-config.sh -k "ssh-ed25519 AAAA..." --port 22222 --yes
#   sudo ./ssh-config.sh --random-port --yes

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

_bootstrap_ssh_lib() {
  [[ -n "${SCRIPTS_SSH_LOADED:-}" ]] && return 0
  local lib=""
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/fd/"* && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/ssh.sh"
  fi
  if [[ -n "$lib" && -f "$lib" ]]; then
    # shellcheck source=lib/ssh.sh
    source "$lib"
  else
    local tmp; tmp="$(mktemp)"
    curl -fsSL "${SCRIPTS_RAW_BASE}/lib/ssh.sh?v=$(date +%s)" -o "$tmp" \
      || { die "Failed to fetch lib/ssh.sh"; }
    source "$tmp"
    rm -f "$tmp"
  fi
}

_bootstrap_lib
_bootstrap_ssh_lib

# ---------- constants ----------

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_D_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_D_DIR}/99-custom.conf"
PORT_MARKER="/etc/ssh/.custom_port"

MIN_PORT=10000
MAX_PORT=65000

MAX_AUTH_TRIES_DEFAULT="6"
MAX_SESSIONS_DEFAULT="4"
MAX_STARTUPS_DEFAULT="10:30:60"

# ---------- sshd binary / config test ----------

sshd_bin() {
  if command -v sshd >/dev/null 2>&1; then echo "sshd"; return; fi
  [[ -x /usr/sbin/sshd ]] && { echo "/usr/sbin/sshd"; return; }
  die "sshd binary not found"
}

test_sshd() {
  local sbin; sbin="$(sshd_bin)"
  "$sbin" -t >/dev/null 2>&1
}

# ---------- /run/sshd ----------

# sshd needs /run/sshd for privilege separation. It lives on tmpfs and
# vanishes on reboot. We create it now and register it in tmpfiles.d so
# systemd recreates it on every boot automatically.
ensure_run_sshd() {
  mkdir -p /run/sshd
  chmod 0755 /run/sshd
  if [[ -d /etc/tmpfiles.d ]]; then
    echo "d /run/sshd 0755 root root -" >/etc/tmpfiles.d/sshd.conf
    ok "Registered /run/sshd in /etc/tmpfiles.d/sshd.conf (survives reboots)"
  else
    warn "/etc/tmpfiles.d not found; /run/sshd will be missing after next reboot"
  fi
}

# ---------- systemd unit detection ----------

choose_ssh_service_unit() {
  unit_present "sshd.service" && { echo "sshd.service"; return; }
  unit_present "ssh.service"  && { echo "ssh.service";  return; }
  echo ""
}

choose_ssh_socket_unit() {
  unit_present "sshd.socket" && { echo "sshd.socket"; return; }
  unit_present "ssh.socket"  && { echo "ssh.socket";  return; }
  echo ""
}

detect_mode() {
  if has_systemd; then
    local svc sock
    svc="$(choose_ssh_service_unit)"
    sock="$(choose_ssh_socket_unit)"
    if [[ -n "$svc" ]]; then echo "service"; return; fi
    if [[ -n "$sock" ]]; then echo "socket"; return; fi
  fi
  echo "legacy"
}

# ---------- firewall / SELinux helpers ----------

configure_firewall() {
  local port="$1"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "UFW: allowing ${port}/tcp"
    ufw allow "${port}/tcp" comment "SSH" >/dev/null 2>&1 || die "UFW failed"
    ok "UFW updated"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && has_systemd && systemctl is-active firewalld >/dev/null 2>&1; then
    info "firewalld: allowing ${port}/tcp"
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || die "firewalld failed"
    firewall-cmd --reload >/dev/null 2>&1 || die "firewalld reload failed"
    ok "firewalld updated"
  fi

  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    if ! command -v semanage >/dev/null 2>&1; then
      warn "SELinux Enforcing + semanage missing; SSH may fail on non-default port."
      warn "Install: dnf/yum install -y policycoreutils-python-utils"
    else
      info "SELinux: allowing ssh_port_t for ${port}/tcp"
      semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || \
      semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null || true
      ok "SELinux updated"
    fi
  fi
}

verify_listening() {
  local port="$1" i
  for i in {1..12}; do
    sleep 1
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${port}$" && return 0
    elif command -v netstat >/dev/null 2>&1; then
      netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${port}$" && return 0
    fi
  done
  return 1
}

# ---------- sshd_config handling ----------

apply_sshd_dropin() {
  local content="$1"
  mkdir -p "$SSHD_D_DIR"
  mk_backup "$SSHD_DROPIN"
  write_atomic "$SSHD_DROPIN" <<<"$content"
  ok "Wrote drop-in: $SSHD_DROPIN"
  test_sshd || die "Invalid sshd config after writing $SSHD_DROPIN. Run: $(sshd_bin) -t"
  ok "sshd config test OK"
}

# ---------- systemd socket drop-in ----------

socket_dropin_path() { echo "/etc/systemd/system/${1}.d/99-custom.conf"; }

have_ipv6() {
  [[ -f /proc/net/if_inet6 ]] && grep -q . /proc/net/if_inet6 2>/dev/null
}

apply_socket_port_dropin() {
  local sock_unit="$1" port="$2"
  local path; path="$(socket_dropin_path "$sock_unit")"

  local content
  if have_ipv6; then
    local ipv6_busy="false"
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "^\[.*\]:${port}$" && ipv6_busy="true"
    fi
    if [[ "$ipv6_busy" == "false" ]]; then
      content="$(cat <<EOF
# Managed by ssh-config.sh
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
EOF
)"
    else
      warn "IPv6 port ${port} appears busy; using IPv4-only ListenStream."
      content="$(cat <<EOF
# Managed by ssh-config.sh
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
EOF
)"
    fi
  else
    content="$(cat <<EOF
# Managed by ssh-config.sh
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
EOF
)"
  fi

  mk_backup "$path"
  write_atomic "$path" <<<"$content"
  ok "Wrote systemd drop-in: $path"
}

# ---------- restart / diagnostics ----------

print_unit_debug() {
  local unit="$1"
  warn "---- systemctl status ${unit} ----"
  systemctl status "$unit" --no-pager -l >&2 || true
  warn "---- journalctl -u ${unit} (last 30 lines) ----"
  journalctl -u "$unit" -b --no-pager -n 30 >&2 || true
}

kill_unmanaged_sshd_listener() {
  local svc="${1:-}" sock="${2:-}"
  local systemd_pid="0"
  if [[ -n "$svc" ]] && has_systemd; then
    systemd_pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || echo 0)"
  fi
  local listener_pids
  listener_pids="$(ss -tlnp 2>/dev/null \
    | grep -oE 'pid=[0-9]+' \
    | cut -d= -f2 \
    | sort -u || true)"
  local killed=0 pid
  for pid in $listener_pids; do
    [[ -z "$pid" || "$pid" == "0" ]] && continue
    [[ "$pid" == "$systemd_pid" ]] && continue
    local comm; comm="$(cat /proc/"$pid"/comm 2>/dev/null || true)"
    [[ "$comm" == sshd ]] || continue
    info "Stopping unmanaged sshd listener (pid=$pid)"
    kill "$pid" 2>/dev/null || true
    (( killed++ ))
  done
  [[ "$killed" -gt 0 ]] && sleep 1
  return 0
}

restart_ssh_once() {
  local mode="$1"
  ensure_run_sshd
  if has_systemd; then
    systemctl daemon-reload || true
    local svc sock
    svc="$(choose_ssh_service_unit)"
    sock="$(choose_ssh_socket_unit)"
    if [[ "$mode" == "service" && -n "$svc" ]]; then
      info "Restarting SSH via service unit: $svc"
      kill_unmanaged_sshd_listener "$svc" "$sock"
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl enable "$svc" >/dev/null 2>&1 || true
      if [[ -n "$sock" ]]; then
        systemctl stop "$sock" 2>/dev/null || true
        systemctl unmask "$sock" >/dev/null 2>&1 || true
      fi
      systemctl restart "$svc" || { print_unit_debug "$svc"; return 1; }
      ok "SSH restarted via $svc"
      return 0
    fi
    if [[ "$mode" == "socket" && -n "$sock" ]]; then
      info "Restarting SSH via socket activation: $sock"
      kill_unmanaged_sshd_listener "$svc" "$sock"
      systemctl unmask "$sock" >/dev/null 2>&1 || true
      systemctl enable --now "$sock" >/dev/null 2>&1 || true
      systemctl restart "$sock" || { print_unit_debug "$sock"; return 1; }
      ok "SSH available via socket activation ($sock)"
      return 0
    fi
  fi
  info "Restarting SSH via legacy service command..."
  service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || return 1
  ok "SSH restarted via legacy service command"
  return 0
}

# ---------- key handling ----------

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
  ok "Key added to $ak"
  return 0
}

# ---------- usage ----------

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
  -y, --yes           Skip confirmations
  -h, --help          Show help
EOF
}

# ---------- main ----------

main() {
  is_root || die "Run as root (sudo)."
  need sed; need awk; need grep; need date; need mktemp
  [[ -f "$SSHD_MAIN" ]] || die "SSH config not found: $SSHD_MAIN"
  sshd_bin >/dev/null

  ensure_run_sshd

  local key_mode="false" key_arg=""
  local assume_yes="false"
  local port_mode="none" port_value=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -k|--key)
        key_mode="true"
        shift || true
        if [[ $# -gt 0 && "${1:-}" != -* ]]; then key_arg="$1"; shift || true; fi
        ;;
      --port)
        shift || true
        [[ $# -gt 0 ]] || die "--port requires a value"
        port_mode="manual"
        port_value="$1"
        shift || true
        ;;
      --random-port) port_mode="random"; shift || true ;;
      -y|--yes) assume_yes="true"; shift || true ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local mode; mode="$(detect_mode)"
  local sock; sock="$(choose_ssh_socket_unit)"

  # --- key handling ---
  if [[ "$key_mode" == "true" ]]; then
    local u h k
    u="$(current_user)"
    h="$(current_home)"
    [[ -d "$h" ]] || die "Cannot determine home directory for user: $u"
    k="$(read_key "${key_arg:-}")"
    valid_ssh_key "$k" || die "Invalid SSH public key format"
    info "Target user: $u"
    ensure_ssh_dir "$h" "$u"
    add_authorized_key "$k" "$h" "$u" || true
  fi

  # --- port selection ---
  local do_port="false" new_port=""
  if [[ "$port_mode" == "manual" ]]; then
    do_port="true"
    valid_port "$port_value" || die "Invalid --port '$port_value' (must be 1024-65535)"
    port_in_use "$port_value" && die "Port $port_value is in use"
    new_port="$port_value"
  elif [[ "$port_mode" == "random" ]]; then
    do_port="true"
    new_port="$(rand_port "$MIN_PORT" "$MAX_PORT")"
    ok "Generated port: $new_port"
  else
    if [[ "$key_mode" == "false" ]]; then
      has_tty || die "No TTY for interactive mode. Use --port/--random-port."
      info "SSH port change mode"
      if prompt_yn "Generate random port?" "y"; then
        do_port="true"
        new_port="$(rand_port "$MIN_PORT" "$MAX_PORT")"
        ok "Generated port: $new_port"
      else
        local p
        read_tty p "Enter SSH port (1024-65535): " || die "Port prompt failed"
        p="$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        valid_port "$p" || die "Invalid port '$p' (1024-65535)"
        port_in_use "$p" && die "Port $p is in use"
        do_port="true"
        new_port="$p"
        ok "Selected port: $new_port"
      fi
    fi
  fi

  if [[ "$key_mode" == "false" && "$do_port" == "false" ]]; then
    warn "No action requested. Use -k/--key, --port N, or --random-port."
    usage
    exit 1
  fi

  if [[ "$do_port" == "true" && "$assume_yes" != "true" && "$port_mode" != "random" ]]; then
    has_tty || die "No TTY for confirmation. Use --yes."
    echo
    info "Will apply:"
    echo "  Mode          ${mode}"
    echo "  Port          ${new_port}"
    echo "  MaxAuthTries  ${MAX_AUTH_TRIES_DEFAULT}"
    echo "  MaxSessions   ${MAX_SESSIONS_DEFAULT}"
    echo "  MaxStartups   ${MAX_STARTUPS_DEFAULT}"
    echo
    prompt_yn "Continue?" "y" || { echo "Cancelled"; exit 0; }
  fi

  if [[ "$do_port" == "true" ]]; then
    configure_firewall "$new_port"
    echo "$new_port" >"$PORT_MARKER" || true
  fi

  local sshd_lines=()
  if [[ "$key_mode" == "true" ]]; then
    sshd_lines+=("PubkeyAuthentication yes")
    sshd_lines+=("PasswordAuthentication no")
    sshd_lines+=("KbdInteractiveAuthentication no")
    sshd_lines+=("ChallengeResponseAuthentication no")
  fi
  if [[ "$do_port" == "true" ]]; then
    sshd_lines+=("MaxAuthTries ${MAX_AUTH_TRIES_DEFAULT}")
    sshd_lines+=("MaxSessions ${MAX_SESSIONS_DEFAULT}")
    sshd_lines+=("MaxStartups ${MAX_STARTUPS_DEFAULT}")
    if [[ "$mode" != "socket" ]]; then
      sshd_lines+=("Port ${new_port}")
    fi
  fi
  if [[ "${#sshd_lines[@]}" -gt 0 ]]; then
    apply_sshd_dropin "$(printf "%s\n" "${sshd_lines[@]}")"
  else
    test_sshd || die "sshd config test failed"
  fi

  # ---- apply + restart ----
  if [[ "$mode" == "socket" && "$do_port" == "true" ]]; then
    [[ -n "$sock" ]] || die "socket mode detected but no ssh socket unit found"
    if [[ "$port_mode" == "random" ]]; then
      local tries=0 max=30
      while true; do
        (( tries++ ))
        if port_in_use "$new_port"; then
          new_port="$(rand_port "$MIN_PORT" "$MAX_PORT")"
          ok "Generated port: $new_port"
          continue
        fi
        apply_socket_port_dropin "$sock" "$new_port"
        if restart_ssh_once "socket"; then break; fi
        warn "Socket restart failed on port $new_port (attempt $tries/$max). Picking new port..."
        [[ $tries -ge $max ]] && die "Failed to apply random port after $max attempts"
        new_port="$(rand_port "$MIN_PORT" "$MAX_PORT")"
        ok "Generated port: $new_port"
      done
    else
      apply_socket_port_dropin "$sock" "$new_port"
      restart_ssh_once "socket" || die "Failed to restart $sock"
    fi
  else
    restart_ssh_once "$mode" || die "Failed to restart SSH"
  fi

  if [[ "$do_port" == "true" ]]; then
    if verify_listening "$new_port"; then
      ok "SSH is listening on port $new_port"
    else
      warn "Could not verify listening on port $new_port (try: ss -tln | grep :$new_port)"
    fi
    echo
    warn "IMPORTANT: keep this session open. Test in NEW terminal:"
    echo "  ssh -p $new_port user@host"
  else
    echo
    ok "Auth settings applied."
    warn "IMPORTANT: test SSH in a NEW session before closing this one."
  fi
}

main "$@"
