#!/usr/bin/env bash
# revoke-ssh-keys.sh — emergency revocation of ALL authorized SSH keys (post-compromise)
# - removes authorized_keys / authorized_keys2 for root and all real users (with backups)
# - with -k "KEY": installs the given key FIRST, then removes everything except it
# - detects and clears non-standard AuthorizedKeysFile paths (possible backdoors)
# - optionally kills all other active SSH sessions (attacker may still be inside)
# - optionally regenerates SSH host keys
#
# Examples:
#   curl -fsSL URL | sudo bash -s -- -k "ssh-ed25519 AAAA..." --yes --kill-sessions
#   curl -fsSL URL | sudo bash -s -- --yes
#   sudo ./revoke-ssh-keys.sh --yes --kill-sessions --regen-host-keys
#
# Without -k: keep this session open and add your new key immediately after:
#   KEY="ssh-ed25519 AAAA..."
#   curl -fsSL .../ssh-config.sh | sudo bash -s -- -k "$KEY"

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
TS="$(date +%Y%m%d-%H%M%S)"

# ---------- users enumeration ----------

# Outputs lines: "user:home" for root and all real users (uid >= 1000) with existing home dirs
list_target_users() {
  awk -F: '($3 == 0 || $3 >= 1000) && $6 != "" && $6 != "/" && $6 != "/nonexistent" {print $1 ":" $6}' /etc/passwd \
    | while IFS=: read -r u h; do
        [[ -d "$h" ]] && echo "${u}:${h}"
      done
}

# ---------- key install / counting ----------

# Install the new key as the ONLY content of the target user's authorized_keys
install_new_key() {
  local key="$1" user="$2" home="$3"
  local dir="${home}/.ssh" ak="${home}/.ssh/authorized_keys"
  mkdir -p "$dir"
  chmod 700 "$dir"
  chown "$user:$user" "$dir" 2>/dev/null || true
  mk_backup "$ak"
  echo "$key" >"$ak"
  chmod 600 "$ak"
  chown "$user:$user" "$ak" 2>/dev/null || true
  ok "Installed new key as the only key in $ak"
}

count_keys() {
  local f="$1" n
  [[ -f "$f" ]] || { echo 0; return; }
  # grep -c exits 1 when count is 0, so guard with || true
  n="$(grep -cEv '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true)"
  echo "${n:-0}"
}

# ---------- AuthorizedKeysFile detection (backdoor check) ----------

collect_authorized_keys_paths() {
  local files=() f
  [[ -f "$SSHD_MAIN" ]] && files+=("$SSHD_MAIN")
  if [[ -d "$SSHD_D_DIR" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$SSHD_D_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
  fi
  local paths=""
  for f in "${files[@]}"; do
    local vals
    vals="$(grep -iE '^[[:space:]]*AuthorizedKeysFile[[:space:]]' "$f" 2>/dev/null \
      | sed -E 's/^[[:space:]]*[Aa]uthorized[Kk]eys[Ff]ile[[:space:]]+//' || true)"
    [[ -n "$vals" ]] && paths+="${vals} "
  done
  if [[ -z "${paths// /}" ]]; then
    echo ".ssh/authorized_keys .ssh/authorized_keys2"
  else
    echo "$paths"
  fi
}

is_standard_keys_path() {
  case "$1" in
    .ssh/authorized_keys|.ssh/authorized_keys2|%h/.ssh/authorized_keys|%h/.ssh/authorized_keys2|none) return 0 ;;
    *) return 1 ;;
  esac
}

expand_keys_path() {
  local tpl="$1" user="$2" home="$3"
  local p="$tpl"
  p="${p//%%/%}"
  p="${p//%h/$home}"
  p="${p//%u/$user}"
  [[ "$p" == /* ]] || p="${home}/${p}"
  echo "$p"
}

# ---------- kill other SSH sessions ----------

get_ppid() {
  local stat rest
  stat="$(cat /proc/"$1"/stat 2>/dev/null)" || return 0
  rest="${stat##*) }"
  # shellcheck disable=SC2086
  set -- $rest
  echo "${2:-}"
}

my_ancestor_pids() {
  local pid=$$ chain="" guard=0
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
    chain+=" $pid"
    pid="$(get_ppid "$pid")"
    (( ++guard > 64 )) && break
  done
  echo "$chain"
}

listener_sshd_pids() {
  local pids=""
  if command -v ss >/dev/null 2>&1; then
    pids="$(ss -tlnp 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
  fi
  if has_systemd; then
    local u mp
    for u in sshd.service ssh.service; do
      mp="$(systemctl show "$u" -p MainPID --value 2>/dev/null || echo 0)"
      [[ -n "$mp" && "$mp" != "0" ]] && pids+=" $mp"
    done
  fi
  echo "$pids"
}

get_ssh_connection() {
  [[ -n "${SSH_CONNECTION:-}" ]] && { echo "$SSH_CONNECTION"; return 0; }
  local pid=$$ guard=0 v
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
    if [[ -r /proc/$pid/environ ]]; then
      v="$(tr '\0' '\n' < /proc/"$pid"/environ 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -1)"
      [[ -n "$v" ]] && { echo "$v"; return 0; }
    fi
    pid="$(get_ppid "$pid")"
    (( ++guard > 64 )) && break
  done
  return 0
}

my_ssh_server_pid() {
  command -v ss >/dev/null 2>&1 || return 0
  local conn src_ip src_port
  conn="$(get_ssh_connection)"
  [[ -z "$conn" ]] && return 0
  src_ip="$(echo "$conn" | awk '{print $1}')"
  src_port="$(echo "$conn" | awk '{print $2}')"
  [[ -z "$src_ip" || -z "$src_port" ]] && return 0
  ss -tnp 2>/dev/null \
    | grep -F "${src_ip}:${src_port}" \
    | grep -oE 'pid=[0-9]+' \
    | cut -d= -f2 | sort -u | tr '\n' ' ' || true
  return 0
}

in_ssh_session() {
  [[ -n "$(get_ssh_connection)" ]] && return 0
  local pid=$$ guard=0 stat
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
    stat="$(cat /proc/"$pid"/stat 2>/dev/null || true)"
    [[ "$stat" == *"(sshd"* ]] && return 0
    pid="$(get_ppid "$pid")"
    (( ++guard > 64 )) && break
  done
  return 1
}

kill_other_ssh_sessions() {
  local my_server_pids=""
  my_server_pids="$(my_ssh_server_pid)" || true
  if in_ssh_session && [[ -z "${my_server_pids// /}" ]]; then
    warn "Could not positively identify the sshd of the CURRENT session."
    warn "Refusing to kill any SSH sessions to avoid locking you out."
    warn "Kill foreign sessions manually after verifying your own pid:"
    warn "  ss -tnp | grep ssh    # find your client ip:port and its pid"
    warn "  kill <other_session_pids>"
    return 0
  fi
  local keep=" $(listener_sshd_pids) $(my_ancestor_pids) ${my_server_pids} "
  if [[ -n "${my_server_pids// /}" ]]; then
    info "Current session sshd pid(s):${my_server_pids} (protected)"
  fi
  local candidates
  candidates="$( { pgrep -x sshd 2>/dev/null; pgrep -x sshd-session 2>/dev/null; } | sort -u || true)"
  local killed=0 pid comm
  for pid in $candidates; do
    [[ "$keep" == *" $pid "* ]] && continue
    comm="$(cat /proc/"$pid"/comm 2>/dev/null || true)"
    [[ "$comm" == "sshd" || "$comm" == "sshd-session" ]] || continue
    info "Killing SSH session process (pid=$pid, $comm)"
    kill "$pid" 2>/dev/null || true
    (( killed++ )) || true
  done
  if (( killed > 0 )); then
    sleep 1
    for pid in $candidates; do
      [[ "$keep" == *" $pid "* ]] && continue
      kill -9 "$pid" 2>/dev/null || true
    done
    ok "Killed ${killed} foreign SSH session process(es)"
  else
    info "No foreign SSH sessions found"
  fi
}

# ---------- host keys regeneration ----------

restart_sshd() {
  if has_systemd; then
    systemctl daemon-reload || true
    local u
    for u in sshd.service ssh.service; do
      if unit_present "$u" && systemctl is-active "$u" >/dev/null 2>&1; then
        systemctl restart "$u" && { ok "Restarted $u"; return 0; }
      fi
    done
    for u in sshd.socket ssh.socket; do
      if unit_present "$u" && systemctl is-active "$u" >/dev/null 2>&1; then
        systemctl restart "$u" && { ok "Restarted $u"; return 0; }
      fi
    done
    for u in sshd.service ssh.service; do
      unit_present "$u" && systemctl restart "$u" 2>/dev/null && { ok "Restarted $u"; return 0; }
    done
  fi
  service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || return 1
  ok "Restarted SSH via legacy service command"
}

regen_host_keys() {
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
  local bdir="/etc/ssh/host_keys_backup.${TS}"
  mkdir -p "$bdir"
  chmod 700 "$bdir"
  local moved=0 f
  for f in /etc/ssh/ssh_host_*; do
    [[ -e "$f" ]] || continue
    mv -f "$f" "$bdir"/
    (( moved++ )) || true
  done
  ok "Moved ${moved} old host key file(s) to $bdir"
  ssh-keygen -A >/dev/null
  ok "Generated new host keys"
  restart_sshd || warn "Could not restart sshd automatically; restart it manually"
  warn "Clients will see a host key mismatch warning on next connect (expected)."
  warn "Fix locally with: ssh-keygen -R <host>"
}

# ---------- usage ----------

usage() {
  cat <<EOF
Usage:
  sudo $0 -k "ssh-ed25519 AAAA..." [--yes] [--kill-sessions]
  sudo $0 [--yes] [--kill-sessions] [--regen-host-keys]

Removes ALL authorized SSH keys for root and every real user (uid >= 1000).
Backups are kept next to each file as authorized_keys.bak.<timestamp>.

With -k, the given key is installed FIRST and survives the cleanup:
the end result is exactly one authorized key on the whole server.

Options:
  -k, --key [KEY]     Install this public key first, keep ONLY it
                      (if KEY omitted, read from stdin)
  -y, --yes           Skip confirmations
  --kill-sessions     Kill all other active SSH sessions (keeps the current one)
  --regen-host-keys   Regenerate /etc/ssh/ssh_host_* keys and restart sshd
  -h, --help          Show help
EOF
}

# ---------- main ----------

main() {
  is_root || die "Run as root (sudo)."
  command -v awk >/dev/null 2>&1 || die "Command not found: awk"

  local assume_yes="false" do_kill="ask" do_regen="false"
  local key_mode="false" key_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -k|--key)
        key_mode="true"
        shift || true
        if [[ $# -gt 0 && "${1:-}" != -* ]]; then key_arg="$1"; shift || true; fi
        ;;
      -y|--yes) assume_yes="true"; shift ;;
      --kill-sessions) do_kill="true"; shift ;;
      --regen-host-keys) do_regen="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  local new_key="" keep_user="" keep_home="" keep_file=""
  if [[ "$key_mode" == "true" ]]; then
    keep_user="$(current_user)"
    keep_home="$(current_home)"
    [[ -d "$keep_home" ]] || die "Cannot determine home directory for user: $keep_user"
    new_key="$(read_key "${key_arg:-}")"
    valid_ssh_key "$new_key" || die "Invalid SSH public key format"
    keep_file="${keep_home}/.ssh/authorized_keys"
    info "New key will be installed for user '$keep_user' and kept after cleanup"
  fi

  if [[ "$assume_yes" != "true" ]]; then
    has_tty || die "No TTY for confirmation. Use --yes."
    echo
    if [[ "$key_mode" == "true" ]]; then
      warn "This will REMOVE ALL authorized SSH keys for root and every real user,"
      warn "keeping ONLY the new key for user '$keep_user'."
    else
      warn "This will REMOVE ALL authorized SSH keys for root and every real user."
      warn "You will only keep access through the CURRENT session until a new key is added."
    fi
    prompt_yn "Continue?" "n" || { echo "Cancelled"; exit 0; }
  fi

  if [[ "$key_mode" == "true" ]]; then
    install_new_key "$new_key" "$keep_user" "$keep_home"
  fi

  local key_path_templates
  key_path_templates="$(collect_authorized_keys_paths)"
  info "AuthorizedKeysFile paths in effect: ${key_path_templates}"

  local tpl
  for tpl in $key_path_templates; do
    if ! is_standard_keys_path "$tpl"; then
      warn "NON-STANDARD AuthorizedKeysFile detected: '$tpl' — possible backdoor!"
      warn "Review $SSHD_MAIN and $SSHD_D_DIR/*.conf manually."
    fi
  done

  local all_templates=".ssh/authorized_keys .ssh/authorized_keys2 ${key_path_templates}"
  local total_keys=0 total_files=0 users_touched=0 kept_files=0
  local line u h seen_paths=" "
  while IFS= read -r line; do
    u="${line%%:*}"
    h="${line#*:}"
    local user_keys=0 f n
    for tpl in $all_templates; do
      [[ "$tpl" == "none" ]] && continue
      f="$(expand_keys_path "$tpl" "$u" "$h")"
      [[ "$seen_paths" == *" $f "* ]] && continue
      seen_paths+="$f "
      if [[ -n "$keep_file" && "$f" == "$keep_file" ]]; then
        info "Keeping: $f (contains the new key)"
        (( kept_files++ )) || true
        continue
      fi
      [[ -f "$f" ]] || continue
      n="$(count_keys "$f")"
      mk_backup "$f"
      rm -f "$f"
      ok "Removed: $f (${n} key(s))"
      total_keys=$(( total_keys + n ))
      user_keys=$(( user_keys + n ))
      (( total_files++ )) || true
    done
    if (( user_keys > 0 )); then
      info "User '$u': removed ${user_keys} key(s)"
      (( users_touched++ )) || true
    fi
  done < <(list_target_users)

  if (( total_files == 0 )); then
    if (( kept_files > 0 )); then
      ok "No other keys to remove — only the new key remains."
    else
      info "No authorized_keys files found — nothing to remove."
    fi
  else
    ok "Removed ${total_keys} key(s) in ${total_files} file(s) across ${users_touched} user(s)"
  fi

  if [[ "$do_kill" == "ask" && "$assume_yes" != "true" ]] && has_tty; then
    if prompt_yn "Kill all OTHER active SSH sessions (attacker may still be connected)?" "y"; then
      do_kill="true"
    else
      do_kill="false"
    fi
  fi
  if [[ "$do_kill" == "true" ]]; then
    kill_other_ssh_sessions
  elif [[ "$do_kill" == "ask" ]]; then
    warn "Other SSH sessions were NOT killed (use --kill-sessions). Active sessions survive key removal!"
  fi

  if [[ "$do_regen" == "true" ]]; then
    regen_host_keys
  fi

  echo
  ok "SSH keys cleared. Backups: *.bak.${TS}"
  if [[ "$key_mode" == "true" ]]; then
    ok "The ONLY authorized key now belongs to user '$keep_user' ($keep_file)"
    warn "Test login with this key in a NEW terminal before closing this session."
  else
    warn "IMPORTANT: do NOT close this session. Add your new key NOW:"
    echo '  KEY="ssh-ed25519 AAAA..."'
    echo '  curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- -k "$KEY"'
    echo
    warn "Then test login with the new key in a NEW terminal before closing this one."
  fi
}

main "$@"
