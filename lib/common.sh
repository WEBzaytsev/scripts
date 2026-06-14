#!/usr/bin/env bash
# lib/common.sh — shared utilities for WEBzaytsev/scripts
# Source this file; do not execute directly.

# Guard against double-sourcing
[[ -n "${SCRIPTS_COMMON_LOADED:-}" ]] && return 0

# ---------- logging ----------

ok()   { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------- environment ----------

is_root()     { [[ "${EUID}" -eq 0 ]]; }
has_systemd() { command -v systemctl >/dev/null 2>&1; }
has_tty()     { [[ -r /dev/tty ]]; }
need()        { command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"; }

# ---------- file utilities ----------

mk_backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -f "$f" "${f}.bak.${ts}"
  ok "Backup: ${f}.bak.${ts}"
}

write_atomic() {
  local dst="$1" tmp
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod 0644 "$tmp" || true
  mv -f "$tmp" "$dst"
}

# ---------- TTY / prompts ----------

read_tty() {
  local __var="$1" __prompt="$2" __tmp=""
  has_tty || return 1
  if ! IFS= read -r -p "$__prompt" __tmp </dev/tty; then return 1; fi
  printf -v "$__var" "%s" "$__tmp"
}

prompt_yn() {
  local msg="$1" def="${2:-y}" ans
  while true; do
    if ! read_tty ans "${msg} [y/n] (default: ${def}): "; then
      warn "No TTY for prompt: '${msg}'"
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

prompt_string() {
  local var="$1" prompt="$2" default="${3:-}" value=""
  while true; do
    if ! read_tty value "${prompt}${default:+ (default: ${default})}: "; then
      warn "No TTY available for prompt: '${prompt}'"
      return 1
    fi
    value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="${value:-$default}"
    if [[ -n "$value" ]]; then
      printf -v "$var" '%s' "$value"
      return 0
    fi
    warn "Value cannot be empty."
  done
}

# ---------- port utilities ----------

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1024 && p <= 65535 )) || return 1
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$" && return 0
  fi
  return 1
}

rand_port() {
  local min="${1:-10000}" max="${2:-65000}"
  local tries=0 max_tries=120 p
  while (( tries < max_tries )); do
    if command -v shuf >/dev/null 2>&1; then
      p="$(shuf -i "${min}-${max}" -n 1)"
    else
      p=$(( (RANDOM % (max - min + 1)) + min ))
    fi
    if ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
    (( tries++ ))
  done
  die "Failed to find free port after $max_tries tries"
}

prompt_port() {
  local var="$1" prompt="$2" default="${3:-}" value=""
  while true; do
    if ! read_tty value "${prompt}${default:+ (default: ${default})}: "; then
      warn "No TTY available for port prompt."
      return 1
    fi
    value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="${value:-$default}"
    if [[ -z "$value" ]]; then
      warn "Port cannot be empty."
      continue
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
      warn "Invalid port: '$value'. Must be 1-65535."
      continue
    fi
    if port_in_use "$value"; then
      warn "Port $value is in use."
      continue
    fi
    printf -v "$var" '%s' "$value"
    return 0
  done
}

# ---------- misc validation ----------

valid_url() { [[ "$1" =~ ^https?:// ]]; }

valid_ssh_key() {
  local k="$1"
  [[ "$k" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-dss)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] && return 0
  if command -v ssh-keygen >/dev/null 2>&1; then
    echo "$k" | ssh-keygen -l -f - >/dev/null 2>&1 && return 0
  fi
  return 1
}

SCRIPTS_COMMON_LOADED=1
