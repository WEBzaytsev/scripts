#!/bin/sh
# enable-bbr.sh — robust TCP BBR enabler (idempotent, with checks)
# Polished: fixes apt-get update usage, avoids double sysctl --system, better fallbacks & diagnostics.
set -eu

log()  { printf '%s\n' "[INFO] $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
die()  { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  else echo unknown
  fi
}

install_procps_if_needed() {
  # sysctl is provided by procps/procps-ng
  if command -v sysctl >/dev/null 2>&1; then return 0; fi

  pm="$(pm_detect)"
  log "sysctl not found, trying to install it (package: procps / procps-ng)…"
  case "$pm" in
    apt)
      # NOTE: apt-get update does NOT support -y
      apt-get update
      apt-get install -y procps
      ;;
    dnf)
      dnf -y install procps-ng
      ;;
    yum)
      yum -y install procps-ng
      ;;
    apk)
      apk add --no-cache procps
      ;;
    *)
      die "Unsupported package manager. Install sysctl (procps/procps-ng) manually."
      ;;
  esac

  command -v sysctl >/dev/null 2>&1 || die "sysctl still missing after install"
}

backup_file() {
  f="$1"
  [ -f "$f" ] || return 0
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
  cp -f "$f" "${f}.bak.${ts}"
  log "Backup: ${f}.bak.${ts}"
}

atomic_write() {
  dst="$1"
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod 0644 "$tmp" || true
  mv -f "$tmp" "$dst"
}

# Remove existing key lines and ensure key=value present exactly once
ensure_kv_in_file() {
  file="$1"
  key="$2"
  val="$3"

  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  if [ -f "$file" ]; then
    # Delete any existing lines for the key (with optional spaces)
    awk -v k="$key" '
      $0 ~ "^[[:space:]]*"k"[[:space:]]*=" { next }
      { print }
    ' "$file" >"$tmp"
  else
    : >"$tmp"
  fi

  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  chmod 0644 "$tmp" || true
  mv -f "$tmp" "$file"
}

sysctl_apply() {
  # Prefer --system (loads /etc/sysctl.d/*.conf), else fallback.
  # Provide meaningful error output.
  if sysctl --system >/dev/null 2>&1; then
    return 0
  fi

  if [ -f /etc/sysctl.conf ]; then
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || die "sysctl apply failed (sysctl --system and sysctl -p /etc/sysctl.conf)."
    return 0
  fi

  die "No way to apply sysctl settings (sysctl --system failed and /etc/sysctl.conf missing)."
}

get_sysctl() {
  sysctl -n "$1" 2>/dev/null || return 1
}

try_modprobe_bbr() {
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
  fi
}

bbr_available() {
  avail="$(get_sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")"
  echo "$avail" | grep -qw bbr
}

dump_debug() {
  # Helpful diagnostics for containers / restricted environments
  warn "Diagnostics:"
  warn "  kernel: $(uname -r 2>/dev/null || echo unknown)"
  warn "  available_cc: $(get_sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unknown)"
  warn "  current_cc: $(get_sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  warn "  default_qdisc: $(get_sysctl net.core.default_qdisc 2>/dev/null || echo unknown)"
  if command -v lsmod >/dev/null 2>&1; then
    warn "  lsmod tcp_bbr: $(lsmod 2>/dev/null | awk '$1=="tcp_bbr"{print "loaded"; found=1} END{if(!found)print "not_loaded"}')"
  fi
}

main() {
  is_root || die "Run as root (sudo)."

  install_procps_if_needed

  need_cmd sysctl
  need_cmd awk
  need_cmd grep
  need_cmd date
  need_cmd mktemp
  need_cmd uname

  [ -r /proc/sys/net/ipv4/tcp_congestion_control ] || die "Kernel sysctl interface missing: /proc/sys/net/ipv4/tcp_congestion_control"

  try_modprobe_bbr

  if ! bbr_available; then
    dump_debug
    die "BBR is not available on this kernel. You may need a newer kernel that includes tcp_bbr (or you may be inside a restricted container)."
  fi

  conf_d="/etc/sysctl.d"
  conf_file="${conf_d}/99-bbr.conf"
  fallback="/etc/sysctl.conf"

  desired_qdisc="fq"
  desired_cc="bbr"

  if [ -d "$conf_d" ]; then
    if [ -f "$conf_file" ]; then backup_file "$conf_file"; fi
    log "Writing ${conf_file}…"
    atomic_write "$conf_file" <<EOF
# Managed by enable-bbr.sh
net.core.default_qdisc=${desired_qdisc}
net.ipv4.tcp_congestion_control=${desired_cc}
EOF
  else
    warn "/etc/sysctl.d not found; falling back to ${fallback}"
    [ -f "$fallback" ] || : >"$fallback"
    backup_file "$fallback"
    ensure_kv_in_file "$fallback" "net.core.default_qdisc" "$desired_qdisc"
    ensure_kv_in_file "$fallback" "net.ipv4.tcp_congestion_control" "$desired_cc"
  fi

  log "Applying sysctl settings…"
  if ! sysctl_apply; then
    dump_debug
    die "Failed to apply sysctl settings."
  fi

  got_cc="$(get_sysctl net.ipv4.tcp_congestion_control || echo "")"
  got_qdisc="$(get_sysctl net.core.default_qdisc || echo "")"

  if [ "$got_cc" != "$desired_cc" ]; then
    dump_debug
    die "Validation failed: net.ipv4.tcp_congestion_control is '$got_cc' (expected '$desired_cc')"
  fi

  if [ "$got_qdisc" != "$desired_qdisc" ]; then
    warn "default_qdisc is '$got_qdisc' (expected '$desired_qdisc'). BBR can still work, but fq is recommended."
  fi

  log "OK: BBR enabled."
  log "tcp_congestion_control=${got_cc}"
  log "default_qdisc=${got_qdisc}"
}

main "$@"
