#!/usr/bin/env bash
# lib/ssh.sh — SSH-specific utilities for WEBzaytsev/scripts
# Source this file after lib/common.sh; do not execute directly.

# Guard against double-sourcing
[[ -n "${SCRIPTS_SSH_LOADED:-}" ]] && return 0

# ---------- current user (respects sudo) ----------

current_user() { [[ -n "${SUDO_USER:-}" ]] && echo "$SUDO_USER" || echo "$USER"; }
current_home()  { [[ -n "${SUDO_USER:-}" ]] && eval echo "~$SUDO_USER" || echo "$HOME"; }

# ---------- key parsing ----------

# Read and normalize an SSH public key.
# Usage: read_key [KEY_STRING]  (reads stdin if no argument)
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

# ---------- ~/.ssh directory ----------

ensure_ssh_dir() {
  local home="$1" user="$2"
  local dir="${home}/.ssh"
  mkdir -p "$dir"
  chmod 700 "$dir"
  chown "$user:$user" "$dir" 2>/dev/null || true
}

# ---------- systemd unit helpers ----------

unit_present() {
  local u="$1"
  has_systemd || return 1
  systemctl cat "$u" >/dev/null 2>&1
}

SCRIPTS_SSH_LOADED=1
