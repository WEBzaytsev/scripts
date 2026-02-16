#!/usr/bin/env bash
# docker-aliases-install.sh — system-wide docker compose aliases, reliable across bash/zsh modes
#
# Install:
#   - /etc/profile.d/docker-aliases.sh  (aliases definition)
#   - /etc/bash.bashrc                  (loads aliases for interactive non-login bash)
#   - /etc/zsh/zshrc                    (loads aliases for interactive zsh, if present)
#
# Usage:
#   sudo ./docker-aliases-install.sh
#   curl -fsSL "URL?v=$(date +%s)" | sudo bash
#
# Options:
#   --uninstall   remove managed blocks/lines
#   --print       print generated aliases block and exit

set -euo pipefail

ok()   { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

PROFILE_D_DIR="/etc/profile.d"
ALIASES_FILE="${PROFILE_D_DIR}/docker-aliases.sh"

BASH_SYSTEM_RC="/etc/bash.bashrc"
ZSH_SYSTEM_RC="/etc/zsh/zshrc"

MARKER_BEGIN="# >>> docker-aliases (managed) >>>"
MARKER_END="# <<< docker-aliases (managed) <<<"

BASH_LOADER_LINE='[[ -f /etc/profile.d/docker-aliases.sh ]] && . /etc/profile.d/docker-aliases.sh'
ZSH_LOADER_LINE='[[ -f /etc/profile.d/docker-aliases.sh ]] && source /etc/profile.d/docker-aliases.sh'

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

strip_managed_block() {
  local f="$1"
  [[ -f "$f" ]] || { echo ""; return 0; }
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0==b {inblk=1; next}
    $0==e {inblk=0; next}
    !inblk {print}
  ' "$f"
}

aliases_block_content() {
  cat <<'EOF'
# >>> docker-aliases (managed) >>>
# Interactive shells only (skip non-interactive)
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

ensure_aliases_file() {
  local desired final outside
  desired="$(aliases_block_content)"

  if [[ -f "$ALIASES_FILE" ]]; then
    outside="$(strip_managed_block "$ALIASES_FILE")"
  else
    outside=""
  fi

  if [[ -n "${outside//[[:space:]]/}" ]]; then
    final="${outside}"$'\n\n'"${desired}"$'\n'
  else
    final="${desired}"$'\n'
  fi

  if [[ -f "$ALIASES_FILE" ]] && cmp -s <(printf "%s" "$final") "$ALIASES_FILE"; then
    ok "Already up to date: $ALIASES_FILE"
    return 0
  fi

  mk_backup "$ALIASES_FILE"
  write_atomic "$ALIASES_FILE" <<<"$final"
  chmod 0644 "$ALIASES_FILE" || true
  ok "Installed: $ALIASES_FILE"
}

ensure_line_once() {
  local file="$1" line="$2"
  [[ -f "$file" ]] || return 1
  grep -Fqx "$line" "$file" 2>/dev/null && return 0
  mk_backup "$file"
  printf "\n# Load docker aliases (managed)\n%s\n" "$line" >>"$file"
  ok "Patched: $file"
  return 0
}

install_loaders() {
  # bash: required for your case
  if [[ -f "$BASH_SYSTEM_RC" ]]; then
    ensure_line_once "$BASH_SYSTEM_RC" "$BASH_LOADER_LINE" || true
  else
    warn "No $BASH_SYSTEM_RC found; bash non-login shells may not load aliases automatically."
  fi

  # zsh: best effort
  if [[ -f "$ZSH_SYSTEM_RC" ]]; then
    ensure_line_once "$ZSH_SYSTEM_RC" "$ZSH_LOADER_LINE" || true
  else
    warn "No $ZSH_SYSTEM_RC found; skipping zsh global rc patch."
  fi
}

uninstall() {
  info "Uninstalling managed blocks/lines..."

  if [[ -f "$ALIASES_FILE" ]]; then
    local stripped
    stripped="$(strip_managed_block "$ALIASES_FILE")"
    mk_backup "$ALIASES_FILE"
    write_atomic "$ALIASES_FILE" <<<"$stripped"
    ok "Removed managed block from: $ALIASES_FILE"
  else
    ok "No aliases file: $ALIASES_FILE"
  fi

  if [[ -f "$BASH_SYSTEM_RC" ]]; then
    mk_backup "$BASH_SYSTEM_RC"
    sed -i '\|^\[\[ -f /etc/profile\.d/docker-aliases\.sh \]\] && \. /etc/profile\.d/docker-aliases\.sh$|d' "$BASH_SYSTEM_RC" || true
    ok "Cleaned loader line from: $BASH_SYSTEM_RC"
  fi

  if [[ -f "$ZSH_SYSTEM_RC" ]]; then
    mk_backup "$ZSH_SYSTEM_RC"
    sed -i '\|^\[\[ -f /etc/profile\.d/docker-aliases\.sh \]\] && source /etc/profile\.d/docker-aliases\.sh$|d' "$ZSH_SYSTEM_RC" || true
    ok "Cleaned loader line from: $ZSH_SYSTEM_RC"
  fi

  ok "Uninstall complete."
}

post_check() {
  info "Post-check: bash -ic 'type dcpu'"
  if bash -ic 'type dcpu' >/dev/null 2>&1; then
    ok "Verified: aliases load in interactive non-login bash"
  else
    warn "Aliases did NOT load in 'bash -ic'."
    warn "Diagnostics:"
    warn "  - Does /etc/bash.bashrc exist and include the loader line?"
    warn "  - Is /etc/profile.d/docker-aliases.sh readable?"
    warn "Try:"
    echo "  grep -nF \"$BASH_LOADER_LINE\" $BASH_SYSTEM_RC || true"
    echo "  ls -l $ALIASES_FILE"
    die "Post-check failed"
  fi
}

main() {
  is_root || die "Run as root (sudo)."

  local do_uninstall="false"
  local do_print="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uninstall) do_uninstall="true"; shift || true ;;
      --print)     do_print="true"; shift || true ;;
      -h|--help)
        cat <<EOF
Usage:
  sudo $0
  sudo $0 --uninstall
  sudo $0 --print

Installs:
  - $ALIASES_FILE
  - ensures bash loads it via: $BASH_SYSTEM_RC
  - ensures zsh loads it via: $ZSH_SYSTEM_RC (if present)
EOF
        exit 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  if [[ "$do_print" == "true" ]]; then
    aliases_block_content
    exit 0
  fi

  if [[ "$do_uninstall" == "true" ]]; then
    uninstall
    exit 0
  fi

  mkdir -p "$PROFILE_D_DIR"
  ensure_aliases_file
  install_loaders
  post_check

  echo
  info "Apply in current session (optional):"
  echo "  source /etc/profile.d/docker-aliases.sh"
  ok "Done."
}

main "$@"
