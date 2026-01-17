#!/bin/bash
#
# SSH Configuration Script
# Usage: ssh-config.sh [-r|--random]
#
# Options:
#   -r, --random    Generate random port (no prompt)
#
# Tested on: Ubuntu 18.04+, Debian 9+, CentOS 7+, Rocky Linux 8+

set -euo pipefail

# === CONSTANTS ===
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly PORT_MARKER="/etc/ssh/.custom_port"
readonly MIN_PORT=10000
readonly MAX_PORT=65000

# === COLORS ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# === FUNCTIONS ===
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }

die() {
    log_err "$*"
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

check_dependencies() {
    local deps=(sed awk grep ss systemctl)
    for cmd in "${deps[@]}"; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
    [[ -f "$SSHD_CONFIG" ]] || die "SSH config not found: $SSHD_CONFIG"
}

get_config_value() {
    local key="$1"
    grep -E "^${key}[[:space:]]+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | tail -1
}

get_listening_port() {
    ss -tlnp 2>/dev/null | grep -E '"sshd"|"ssh"' | grep -oE ':[0-9]+' | head -1 | tr -d ':' || echo ""
}

is_port_in_use() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"
}

generate_random_port() {
    local port attempts=0 max_attempts=50
    while ((attempts < max_attempts)); do
        port=$((RANDOM % (MAX_PORT - MIN_PORT + 1) + MIN_PORT))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    die "Failed to find available port after $max_attempts attempts"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((port >= 1024 && port <= 65535)) || return 1
    return 0
}

prompt_port() {
    local port
    while true; do
        read -rp "Enter SSH port (1024-65535): " port </dev/tty
        if validate_port "$port"; then
            echo "$port"
            return 0
        fi
        log_warn "Invalid port. Must be 1024-65535"
    done
}

backup_config() {
    local backup="${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$SSHD_CONFIG" "$backup"
    log_ok "Backup: $backup"
}

set_sshd_option() {
    local key="$1" value="$2"
    # Remove existing (commented or not)
    sed -i "/^[#[:space:]]*${key}[[:space:]]/d" "$SSHD_CONFIG"
    # Append new value
    echo "${key} ${value}" >> "$SSHD_CONFIG"
    log_ok "Set: ${key} ${value}"
}

test_sshd_config() {
    if ! sshd -t 2>/dev/null; then
        return 1
    fi
    return 0
}

disable_ssh_socket() {
    if systemctl is-enabled ssh.socket &>/dev/null; then
        log_info "Disabling ssh.socket..."
        systemctl disable ssh.socket &>/dev/null || true
        systemctl stop ssh.socket &>/dev/null || true
        log_ok "ssh.socket disabled"
    fi
}

restart_ssh() {
    log_info "Restarting SSH..."
    if systemctl list-unit-files | grep -q "^sshd.service"; then
        systemctl restart sshd
    elif systemctl list-unit-files | grep -q "^ssh.service"; then
        systemctl restart ssh
    else
        service sshd restart 2>/dev/null || service ssh restart 2>/dev/null || die "Failed to restart SSH"
    fi
    log_ok "SSH restarted"
}

configure_firewall() {
    local port="$1"
    
    # UFW
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "Configuring UFW..."
        ufw allow "$port/tcp" comment "SSH" >/dev/null 2>&1
        log_ok "UFW: port $port allowed"
    fi
    
    # firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_ok "firewalld: port $port allowed"
    fi
    
    # SELinux
    if command -v semanage &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
        log_info "Configuring SELinux..."
        semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null || true
        log_ok "SELinux: port $port allowed"
    fi
}

verify_ssh_listening() {
    local port="$1" attempts=0 max_attempts=5
    while ((attempts < max_attempts)); do
        sleep 1
        if ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            return 0
        fi
        ((attempts++))
    done
    return 1
}

show_current_settings() {
    local config_port listen_port
    config_port=$(get_config_value "Port")
    config_port=${config_port:-22}
    listen_port=$(get_listening_port)
    listen_port=${listen_port:-unknown}
    
    echo ""
    echo -e "${YELLOW}Current settings:${NC}"
    echo "  Port (config): $config_port"
    echo "  Port (actual): $listen_port"
    echo "  MaxAuthTries:  $(get_config_value "MaxAuthTries" || echo "default")"
    echo "  MaxSessions:   $(get_config_value "MaxSessions" || echo "default")"
    echo "  MaxStartups:   $(get_config_value "MaxStartups" || echo "default")"
    echo ""
    
    # Return current port for checks
    if [[ "$listen_port" != "unknown" ]]; then
        echo "$listen_port"
    else
        echo "$config_port"
    fi
}

show_usage() {
    echo "Usage: $0 [-r|--random]"
    echo ""
    echo "Options:"
    echo "  -r, --random    Generate random port automatically"
    echo "  -h, --help      Show this help"
    exit 0
}

# === MAIN ===
main() {
    local random_mode=false
    local new_port current_port
    
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--random) random_mode=true; shift ;;
            -h|--help) show_usage ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}       SSH Configuration Script         ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    
    # Checks
    check_root
    check_dependencies
    
    # Show current settings and get current port
    current_port=$(show_current_settings | tail -1)
    
    # Warn if already changed
    if [[ "$current_port" != "22" ]]; then
        echo -e "${RED}WARNING: SSH port already changed to $current_port${NC}"
        if [[ "$random_mode" == false ]]; then
            read -rp "Continue anyway? (y/n): " confirm </dev/tty
            [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 0; }
        fi
        echo ""
    fi
    
    # Get new port
    if [[ "$random_mode" == true ]]; then
        log_info "Generating random port..."
        new_port=$(generate_random_port)
        log_ok "Generated port: $new_port"
    else
        new_port=$(prompt_port)
    fi
    
    # Check if already configured
    if [[ "$current_port" == "$new_port" ]] && \
       [[ "$(get_config_value "MaxAuthTries")" == "6" ]] && \
       [[ "$(get_config_value "MaxSessions")" == "4" ]] && \
       [[ "$(get_config_value "MaxStartups")" == "10:30:60" ]]; then
        echo ""
        log_ok "Already configured. Nothing to do."
        exit 0
    fi
    
    # Confirm
    echo ""
    echo -e "${YELLOW}Will apply:${NC}"
    echo "  Port:          $new_port"
    echo "  MaxAuthTries:  6"
    echo "  MaxSessions:   4"
    echo "  MaxStartups:   10:30:60"
    echo ""
    
    if [[ "$random_mode" == false ]]; then
        read -rp "Continue? (y/n): " confirm </dev/tty
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled"; exit 0; }
    fi
    
    # Apply
    echo ""
    backup_config
    
    set_sshd_option "Port" "$new_port"
    set_sshd_option "MaxAuthTries" "6"
    set_sshd_option "MaxSessions" "4"
    set_sshd_option "MaxStartups" "10:30:60"
    
    # Save marker
    echo "$new_port" > "$PORT_MARKER"
    log_ok "Port marker saved"
    
    # Test config
    echo ""
    log_info "Testing config..."
    if ! test_sshd_config; then
        log_err "Config error! Check sshd_config"
        exit 1
    fi
    log_ok "Config syntax OK"
    
    # Firewall
    configure_firewall "$new_port"
    
    # Disable socket activation
    disable_ssh_socket
    
    # Restart
    echo ""
    restart_ssh
    
    # Verify
    log_info "Verifying..."
    if verify_ssh_listening "$new_port"; then
        log_ok "SSH listening on port $new_port"
    else
        log_warn "Could not verify SSH on port $new_port"
        log_warn "Check: ss -tlnp | grep $new_port"
    fi
    
    # Done
    echo ""
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}              COMPLETE                  ${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}SSH Port: ${GREEN}${new_port}${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Keep this session open!${NC}"
    echo -e "${YELLOW}Test: ssh -p $new_port user@host${NC}"
    echo ""
}

main "$@"
