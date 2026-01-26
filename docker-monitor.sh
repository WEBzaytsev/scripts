#!/usr/bin/env bash
# docker-monitor.sh — setup dozzle + beszel agents via docker compose
# Usage: sudo ./docker-monitor.sh
#
# Notes:
# - Requires Docker + Docker Compose (docker-compose OR docker compose plugin)
# - Requires TTY (interactive prompts)
# - Beszel HUB_URL is REQUIRED (without it agent won't work as intended)

set -euo pipefail

LOCK_FILE="/var/run/docker-monitor.lock"
INSTALL_DIR="/opt/docker-monitor"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"

# Defaults (can be overridden by .env or prompts)
DOZZLE_HOSTNAME_DEFAULT=""
DOZZLE_PORT_DEFAULT="7007"
BESZEL_LISTEN_DEFAULT="45876"
BESZEL_KEY_DEFAULT=""
BESZEL_TOKEN_DEFAULT=""
BESZEL_HUB_URL_DEFAULT=""

ok()   { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"; }
is_root() { [[ "${EUID}" -eq 0 ]]; }
has_tty() { [[ -r /dev/tty ]]; }

check_docker() {
  if ! docker info >/dev/null 2>&1; then
    die "Docker is not running or not accessible. Start docker service first."
  fi
}

# ---- lock protection ----
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
      die "Another instance is running (PID: $pid). If stuck, remove: $LOCK_FILE"
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ >"$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}
trap release_lock EXIT

# ---- robust input ----
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

    printf -v "$var" '%s' "$value"
    return 0
  done
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

# ---- validation ----
valid_ssh_key() {
  local k="$1"
  [[ "$k" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-dss)[[:space:]]+[A-Za-z0-9+/=]+ ]] && return 0
  if command -v ssh-keygen >/dev/null 2>&1; then
    echo "$k" | ssh-keygen -l -f - >/dev/null 2>&1 && return 0
  fi
  return 1
}

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --hub-url URL    Beszel hub URL (overrides .env / prompt)
  -h, --help       Show help
EOF
}

# ---- compose generation ----
generate_compose() {
  local dozzle_hostname="$1"
  local dozzle_port="$2"
  local beszel_listen="$3"
  local beszel_key="$4"
  local beszel_token="$5"
  local beszel_hub_url="$6"

  cat <<EOF
services:
  beszel-agent:
    image: henrygd/beszel-agent
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./beszel_agent_data:/var/lib/beszel-agent
    environment:
      LISTEN: "${beszel_listen}"
      KEY: "${beszel_key}"
      TOKEN: "${beszel_token}"
      HUB_URL: "${beszel_hub_url}"

  dozzle-agent:
    image: amir20/dozzle:latest
    command: agent
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "${dozzle_port}:7007"
    environment:
      DOZZLE_HOSTNAME: "${dozzle_hostname}"
EOF
}

main() {
  is_root || die "Run as root (sudo)."

  local hub_url_arg=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hub-url)
        shift || true
        [[ $# -gt 0 ]] || die "--hub-url requires a value"
        hub_url_arg="$1"
        shift || true
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  acquire_lock

  need docker
  check_docker

  # Detect docker compose command (must exist)
  local compose_cmd=""
  if command -v docker-compose >/dev/null 2>&1; then
    compose_cmd="docker-compose"
  elif docker compose version >/dev/null 2>&1; then
    compose_cmd="docker compose"
  else
    die "Docker Compose not found. Install docker-compose or docker compose plugin."
  fi

  has_tty || die "No TTY available. This script requires interactive input."

  # Load .env if exists
  if [[ -f "$ENV_FILE" ]]; then
    info "Loading variables from ${ENV_FILE}..."
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null || true
    set +a
  fi

  # Use env vars, args, or defaults
  local dozzle_hostname="${DOZZLE_HOSTNAME:-$DOZZLE_HOSTNAME_DEFAULT}"
  local dozzle_port="${DOZZLE_PORT:-$DOZZLE_PORT_DEFAULT}"
  local beszel_listen="${BESZEL_LISTEN:-$BESZEL_LISTEN_DEFAULT}"
  local beszel_key="${BESZEL_KEY:-$BESZEL_KEY_DEFAULT}"
  local beszel_token="${BESZEL_TOKEN:-$BESZEL_TOKEN_DEFAULT}"
  local beszel_hub_url="${hub_url_arg:-${BESZEL_HUB_URL:-$BESZEL_HUB_URL_DEFAULT}}"

  echo
  info "Docker Monitor Setup (dozzle + beszel)"
  echo

  # Prompt for values
  prompt_string dozzle_hostname "Dozzle hostname" "$dozzle_hostname" || die "Failed to get hostname"
  prompt_port dozzle_port "Dozzle external port" "$dozzle_port" || die "Failed to get dozzle port"
  prompt_port beszel_listen "Beszel listen port" "$beszel_listen" || die "Failed to get beszel listen port"

  while true; do
    prompt_string beszel_key "Beszel SSH key" "$beszel_key" || die "Failed to get beszel key"
    if valid_ssh_key "$beszel_key"; then
      break
    fi
    warn "Invalid SSH key format. Expected: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp*, or ssh-dss"
    beszel_key=""
  done

  while true; do
    prompt_string beszel_token "Beszel token" "$beszel_token" || die "Failed to get beszel token"
    [[ -n "$beszel_token" ]] && break
    warn "Token cannot be empty."
    beszel_token=""
  done

  # HUB_URL is REQUIRED
  while true; do
    prompt_string beszel_hub_url "Beszel hub URL (required, e.g. https://hub.example.com)" "$beszel_hub_url" || die "Failed to get hub URL"
    [[ -n "$beszel_hub_url" ]] && break
    warn "Hub URL cannot be empty."
    beszel_hub_url=""
  done

  echo
  info "Configuration:"
  echo "  Dozzle hostname: $dozzle_hostname"
  echo "  Dozzle port:     $dozzle_port"
  echo "  Beszel listen:   $beszel_listen"
  echo "  Beszel hub:      $beszel_hub_url"
  echo

  prompt_yn "Continue?" "y" || { echo "Cancelled"; exit 0; }

  mkdir -p "$INSTALL_DIR"
  ok "Created directory: $INSTALL_DIR"

  generate_compose \
    "$dozzle_hostname" \
    "$dozzle_port" \
    "$beszel_listen" \
    "$beszel_key" \
    "$beszel_token" \
    "$beszel_hub_url" > "$COMPOSE_FILE"
  ok "Generated: $COMPOSE_FILE"

  # Save .env for future runs
  {
    echo "DOZZLE_HOSTNAME=${dozzle_hostname}"
    echo "DOZZLE_PORT=${dozzle_port}"
    echo "BESZEL_LISTEN=${beszel_listen}"
    # Quote potentially complex values safely for bash source
    printf "BESZEL_KEY=%q\n" "$beszel_key"
    printf "BESZEL_TOKEN=%q\n" "$beszel_token"
    printf "BESZEL_HUB_URL=%q\n" "$beszel_hub_url"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Saved config: $ENV_FILE"

  info "Starting docker compose..."
  cd "$INSTALL_DIR" || die "Failed to cd to $INSTALL_DIR"

  if $compose_cmd up -d; then
    ok "Services started"
    echo
    info "Check status:"
    echo "  cd $INSTALL_DIR && $compose_cmd ps"
    echo "  cd $INSTALL_DIR && $compose_cmd logs -f"
  else
    warn "Failed to start services. Check logs:"
    echo "  cd $INSTALL_DIR && $compose_cmd logs"
    exit 1
  fi
}

main "$@"
