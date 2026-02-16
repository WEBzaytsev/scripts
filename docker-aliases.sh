#!/usr/bin/env bash
# install-docker-aliases.sh — install docker aliases system-wide (idempotent)
# Usage:
#   sudo ./install-docker-aliases.sh
#   sudo ./install-docker-aliases.sh --user username   # optional: also add to user's ~/.bashrc

set -euo pipefail

ok()   { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

PROFILE_D_FILE="/etc/profile.d/docker-aliases.sh"
MARKER_BEGIN="# >>> docker-aliases (managed) >>>"
MARKER_END="# <<< docker-aliases (managed) <<<"

usage() {
  cat <<EOF
Usage:
  sudo $0
  sudo $0 --user USERNAME

Installs docker aliases system-wide at:
  ${PROFILE_D_FILE}

Optionally, with --user, also ensures Bash users load aliases via ~/.bashrc
EOF
}

mk_backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -f "$f" "${f}.bak.${ts}"
  ok "Backup: ${f}.bak.${ts}"
}

write_atomic() {
  local dst="$1" tmp
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod 0644 "$tmp" || true
  mv -f "$tmp" "$dst"
}

# Remove managed block if present (keeps the rest intact)
strip_managed_block() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    return 0
  fi
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0==b {inblk=1; next}
    $0==e {inblk=0; next}
    !inblk {print}
  ' "$f"
}

managed_block_content() {
  cat <<'EOF'
# >>> docker-aliases (managed) >>>
# Loaded for interactive shells only
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

alias dc='docker compose'
alias dcu='docker compose up'
alias dcud='docker compose up -d'
alias dcub='docker compose up -d --build'
alias dcuw='docker compose up -w'
alias dcd='docker compose down'
alias dcs='docker compose stop'
alias dcb='docker compose build'
alias dcp='docker system prune'
alias dce='docker exec -it'
alias dcl='docker compose logs -f'
alias dclf='docker compose logs -f --tail 100'
alias dcps='docker ps --format="table {{.Names}}\t{{.Ports}}\t{{.Status}}"'
alias dcpu='docker compose pull && docker compose up -d && docker compose ps --format "table {{.Names}}\t{{.Image}}"'
alias dcr='docker compose stop && docker compose up -d --force-recreate'
alias dct='truncate -s 0 /var/lib/docker/containers/*/*-json.log'
alias dcc='docker exec -w /etc/caddy caddy caddy fmt --overwrite && docker exec -w /etc/caddy caddy caddy reload'
alias dccf='docker exec -w /etc/caddy caddy caddy fmt --overwrite && docker exec -w /etc/caddy caddy caddy reload --force'
alias docker-compose='docker compose'
# <<< docker-aliases (managed) <<<
EOF
}

ensure_profiled_installed() {
  local desired tmp
  desired="$(managed_block_content)"

  if [[ -f "$PROFILE_D_FILE" ]]; then
    tmp="$(strip_managed_block "$PROFILE_D_FILE")"
  else
    tmp=""
  fi

  # normalize: trim trailing whitespace lines
  tmp="$(printf "%s\n" "$tmp" | sed '/^[[:space:]]*$/N;/^\n$/D')"

  local final
  if [[ -n "${tmp//[[:space:]]/}" ]]; then
    final="${tmp}"$'\n\n'"${desired}"$'\n'
  else
    final="${desired}"$'\n'
  fi

  # Write only if changed
  if [[ -f "$PROFILE_D_FILE" ]] && cmp -s <(printf "%s" "$final") "$PROFILE_D_FILE"; then
    ok "Already up to date: $PROFILE_D_FILE"
    return 0
  fi

  mk_backup "$PROFILE_D_FILE"
  write_atomic "$PROFILE_D_FILE" <<<"$final"
  ok "Installed: $PROFILE_D_FILE"
}

ensure_user_bashrc_sources_profiled() {
  local user="$1"
  local home
  home="$(eval echo "~$user")"
  [[ -d "$home" ]] || die "Home dir not found for user: $user"

  local bashrc="${home}/.bashrc"
  local line='[ -f /etc/profile ] && . /etc/profile'

  # If .bashrc doesn't exist, create it
  if [[ ! -f "$bashrc" ]]; then
    touch "$bashrc"
    chown "$user:$user" "$bashrc" 2>/dev/null || true
  fi

  # Add line only if missing (some distros already source /etc/profile)
  if ! grep -Fqx "$line" "$bashrc" 2>/dev/null; then
    mk_backup "$bashrc"
    printf "\n# Ensure /etc/profile.d scripts are loaded\n%s\n" "$line" >>"$bashrc"
    chown "$user:$user" "$bashrc" 2>/dev/null || true
    ok "Updated: $bashrc"
  else
    ok "User already sources /etc/profile: $bashrc"
  fi
}

main() {
  is_root || die "Run as root (sudo)."

  local target_user=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        shift || true
        [[ $# -gt 0 ]] || die "--user requires a username"
        target_user="$1"
        shift || true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  mkdir -p /etc/profile.d
  ensure_profiled_installed

  if [[ -n "$target_user" ]]; then
    ensure_user_bashrc_sources_profiled "$target_user"
  fi

  info "How to apply in current session:"
  echo "  source $PROFILE_D_FILE"
  echo "  # or re-login / open new terminal"
  ok "Done."
}

main "$@"
