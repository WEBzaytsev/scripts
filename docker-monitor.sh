#!/usr/bin/env bash
# docker-monitor.sh — setup dozzle + beszel agents via docker compose
#
# Usage: sudo ./docker-monitor.sh [--hub-url URL]
#
# Notes:
# - Requires Docker + Docker Compose (docker-compose OR docker compose plugin)
# - Requires TTY (interactive prompts)
# - Beszel HUB_URL is REQUIRED (without it agent won't work as intended)

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

# ---------- constants ----------

LOCK_FILE="/var/run/docker-monitor.lock"
INSTALL_DIR="/opt/docker-monitor"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"

DOZZLE_PORT_DEFAULT="7007"
BESZEL_LISTEN_DEFAULT="45876"

# ---------- lock protection ----------

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid; pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      die "Another instance is running (PID: $pid). If stuck, remove: $LOCK_FILE"
    fi
    rm -f "$LOCK_FILE"
  fi
  echo $$ >"$LOCK_FILE"
}

release_lock() { rm -f "$LOCK_FILE"; }
trap release_lock EXIT

# ---------- docker ----------

check_docker() {
  if ! docker info >/dev/null 2>&1; then
    die "Docker is not running or not accessible. Start docker service first."
  fi
}

# ---------- compose generation ----------

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

# ---------- usage ----------

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --hub-url URL    Beszel hub URL (overrides .env / prompt)
  -h, --help       Show help
EOF
}

# ---------- main ----------

main() {
  is_root || die "Run as root (sudo)."

  local hub_url_arg=""

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

  local compose_cmd=""
  if command -v docker-compose >/dev/null 2>&1; then
    compose_cmd="docker-compose"
  elif docker compose version >/dev/null 2>&1; then
    compose_cmd="docker compose"
  else
    die "Docker Compose not found. Install docker-compose or docker compose plugin."
  fi

  has_tty || die "No TTY available. This script requires interactive input."

  if [[ -f "$ENV_FILE" ]]; then
    info "Loading variables from ${ENV_FILE}..."
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null || true
    set +a
  fi

  local dozzle_hostname="${DOZZLE_HOSTNAME:-}"
  local dozzle_port="${DOZZLE_PORT:-$DOZZLE_PORT_DEFAULT}"
  local beszel_listen="${BESZEL_LISTEN:-$BESZEL_LISTEN_DEFAULT}"
  local beszel_key="${BESZEL_KEY:-}"
  local beszel_token="${BESZEL_TOKEN:-}"
  local beszel_hub_url="${hub_url_arg:-${BESZEL_HUB_URL:-}}"

  echo
  info "Docker Monitor Setup (dozzle + beszel)"
  echo

  prompt_string dozzle_hostname "Dozzle hostname" "$dozzle_hostname" || die "Failed to get hostname"

  if prompt_yn "Generate random external port for Dozzle?" "y"; then
    dozzle_port="$(rand_port)"
    ok "Generated port: $dozzle_port"
  else
    prompt_port dozzle_port "Dozzle external port" "$dozzle_port" || die "Failed to get dozzle port"
  fi

  if prompt_yn "Generate random listen port for Beszel?" "y"; then
    beszel_listen="$(rand_port)"
    ok "Generated port: $beszel_listen"
  else
    prompt_port beszel_listen "Beszel listen port" "$beszel_listen" || die "Failed to get beszel listen port"
  fi

  while true; do
    prompt_string beszel_key "Beszel SSH key" "$beszel_key" || die "Failed to get beszel key"
    if valid_ssh_key "$beszel_key"; then break; fi
    warn "Invalid SSH key format. Expected: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp*, or ssh-dss"
    beszel_key=""
  done

  while true; do
    prompt_string beszel_token "Beszel token" "$beszel_token" || die "Failed to get beszel token"
    [[ -n "$beszel_token" ]] && break
    warn "Token cannot be empty."
    beszel_token=""
  done

  while true; do
    prompt_string beszel_hub_url "Beszel hub URL (required, e.g. https://hub.example.com)" "$beszel_hub_url" || die "Failed to get hub URL"
    if [[ -n "$beszel_hub_url" ]] && valid_url "$beszel_hub_url"; then break; fi
    warn "Invalid HUB_URL. Must start with http:// or https://"
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

  {
    echo "DOZZLE_HOSTNAME=${dozzle_hostname}"
    echo "DOZZLE_PORT=${dozzle_port}"
    echo "BESZEL_LISTEN=${beszel_listen}"
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
