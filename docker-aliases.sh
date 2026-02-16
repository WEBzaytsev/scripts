#!/usr/bin/env bash
# docker-aliases-install.sh — system-wide docker compose aliases (bash + zsh), reliable & idempotent
#
# Installs:
#   1) /etc/profile.d/docker-aliases.sh     (aliases definition, interactive only)
#   2) ensures loading for:
#        - bash login shells via /etc/profile (default behavior)
#        - bash interactive non-login shells via /etc/bash.bashrc
#        - zsh interactive shells via /etc/zsh/zshrc (if present)
#
# Usage:
#   sudo ./docker-aliases-install.sh
#   curl -fsSL "URL?v=$(date +%s)" | sudo bash
#
# Optional:
#   --uninstall   remove managed blocks
#   --print       print generated aliases file content and exit

set -euo pipefail

ok()   { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

PROFILE_D_DIR="/etc/profile.d"
ALIASES_FILE="${PROFILE_D_DIR}/docker-aliases.sh"

BASH_SYSTEM_RC="/etc/bash.bashrc"   # Debian/Ubuntu global bashrc for interactive non-login shells
ZSH_SYSTEM_RC="/etc/zsh/zshrc"      # common global zshrc path

MARKER_BEGIN="# >>> docker-aliases (managed) >>>"
MARKER_END="# <<< docker-aliases (managed) <<<"

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
  # NOTE: single-quoted heredoc to preserve quotes/backslashes exactly
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
  local desired final existing_stripped
  desired="$(aliases_block_content)"

  if [[ -f "$ALIASES_FILE" ]]; then
    existing_stripped="$(strip_managed_block "$ALIASES_FILE")"
  else
    existing_stripped=""
  fi

  # Keep any custom content outside our markers, then append our managed block.
  if [[ -n "${existing_stripped//[[:space:]]/}" ]]; then
    final="${existing_stripped}"$'\n\n'"${desired}"$'\n'
  else
    final="${desired}"$'\n'
  fi

  # Write only if changed
  if [[ -f "$ALIASES_FILE" ]] && cmp -s <(printf "%s" "$final") "$ALIASES_FILE"; then
    ok "Already up to date: $ALIASES_FILE"
    return 0
  fi

  mk_backup "$ALIASES_FILE"
  write_atomic "$ALIASES_FILE" <<<"$final"
  chmod 0644 "$ALIASES_FILE" || true
  ok "Installed: $ALIASES_FILE"
}

ensure_bash_loads_profiled() {
  # Ensure interactive non-login bash loads /etc/profile.d scripts too.
  # On Debian/Ubuntu, /etc/bash.bashrc is sourced for interactive shells.
  [[ -f "$BASH_SYSTEM_RC" ]] || { warn "No $BASH_SYSTEM_RC found; skipping bash patch."; return 0; }

  local line='[[ -f /etc/profile.d/docker-aliases.sh ]] && . /etc/profile.d/docker-aliases.sh'
  if grep -Fqx "$line" "$BASH_SYSTEM_RC" 2>/dev/null; then
    ok "Bash loader already present: $BASH_SYSTEM_RC"
    return 0
  fi

  mk_backup "$BASH_SYSTEM_RC"
  printf "\n# Load docker aliases (managed)\n%s\n" "$line" >>"$BASH_SYSTEM_RC"
  ok "Patched: $BASH_SYSTEM_RC"
}

ensure_zsh_loads_profiled() {
  # Ensure interactive zsh loads the same aliases file.
  [[ -f "$ZSH_SYSTEM_RC" ]] || { warn "No $ZSH_SYSTEM_RC found; skipping zsh patch."; return 0; }

  local line='[[ -f /etc/profile.d/docker-aliases.sh ]] && source /etc/profile.d/docker-aliases.sh'
  if grep -Fqx "$line" "$ZSH_SYSTEM_RC" 2>/dev/null; then
    ok "Zsh loader already present: $ZSH_SYSTEM_RC"
    return 0
  fi

  mk_backup "$ZSH_SYSTEM_RC"
  printf "\n# Load docker aliases (managed)\n%s\n" "$line" >>"$ZSH_SYSTEM_RC"
  ok "Patched: $ZSH_SYSTEM_RC"
}

uninstall() {
  info "Uninstalling managed blocks..."

  if [[ -f "$ALIASES_FILE" ]]; then
    local stripped
    stripped="$(strip_managed_block "$ALIASES_FILE")"
    mk_backup "$ALIASES_FILE"
    write_atomic "$ALIASES_FILE" <<<"$stripped"
    ok "Removed managed block from: $ALIASES_FILE"
  else
    ok "No aliases file: $ALIASES_FILE"
  fi

  # Remove loader lines (best-effort, only our exact lines)
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

What it does:
  - installs aliases to: $ALIASES_FILE
  - ensures bash interactive shells load it via: $BASH_SYSTEM_RC
  - ensures zsh interactive shells load it via: $ZSH_SYSTEM_RC (if exists)
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
  ensure_bash_loads_profiled
  ensure_zsh_loads_profiled

  echo
  info "Apply in current session:"
  echo "  source /etc/profile.d/docker-aliases.sh"
  echo "Test:"
  echo "  type dcpu"
  ok "Done."
}

main "$@"
