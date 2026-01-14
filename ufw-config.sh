#!/bin/bash

# UFW Firewall Configuration Script
# Tested on: Ubuntu 18.04+, Debian 9+

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    err "Run this script as root"
    exit 1
fi

# Check UFW installed
if ! command -v ufw &>/dev/null; then
    err "UFW not installed. Install with: apt install ufw"
    exit 1
fi

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}      UFW Firewall Configuration       ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Detect SSH port
SSH_PORT=""

# 1. Check marker file from ssh-config.sh
if [[ -f /etc/ssh/.custom_port ]]; then
    SSH_PORT=$(cat /etc/ssh/.custom_port 2>/dev/null)
    echo -e "SSH port (from ssh-config.sh): ${GREEN}$SSH_PORT${NC}"
fi

# 2. Check sshd_config
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(grep -E "^Port[[:space:]]" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
fi

# 3. Check actual listening port
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep -E "sshd|\"ssh\"" | grep -oE ':([0-9]+)' | head -1 | tr -d ':')
fi

# 4. Default to 22
SSH_PORT=${SSH_PORT:-22}

echo -e "SSH port detected: ${GREEN}$SSH_PORT${NC}"

# Detect OpenVPN
OPENVPN_INSTALLED=false
if command -v openvpn &>/dev/null || systemctl list-units --type=service 2>/dev/null | grep -q openvpn; then
    OPENVPN_INSTALLED=true
fi

# Detect Remnawave/Remnanode port
REMNAWAVE_PORT=""
REMNAWAVE_PATHS=(
    "/opt/remnanode/.env"
    "/opt/remnawave/.env"
)

for REMNAWAVE_ENV in "${REMNAWAVE_PATHS[@]}"; do
    if [[ -f "$REMNAWAVE_ENV" ]]; then
        REMNAWAVE_PORT=$(grep -E "^NODE_PORT=" "$REMNAWAVE_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
        if [[ -n "$REMNAWAVE_PORT" ]]; then
            echo -e "Remnanode port: ${GREEN}$REMNAWAVE_PORT${NC} (from $REMNAWAVE_ENV)"
            break
        fi
    fi
done

echo ""
echo -e "${YELLOW}Will configure:${NC}"
echo "  [x] Allow SSH on port $SSH_PORT"
echo "  [x] Allow 443/tcp (HTTPS/VPN)"
if [[ -n "$REMNAWAVE_PORT" ]]; then
    echo "  [x] Allow Remnawave API: $REMNAWAVE_PORT/tcp (detected)"
else
    echo "  [ ] Remnawave: not detected"
fi
if $OPENVPN_INSTALLED; then
    echo "  [x] Allow OpenVPN: 1194/udp (detected)"
else
    echo "  [ ] OpenVPN: not detected"
fi
echo "  [x] Block ICMP ping requests"
echo ""

read -p "Continue? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Cancelled"
    exit 0
fi

echo ""

# Reset UFW to defaults (but don't enable yet)
echo -e "${YELLOW}Resetting UFW to defaults...${NC}"
ufw --force reset >/dev/null 2>&1
log "UFW reset"

# Set default policies
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
log "Default policies set (deny incoming, allow outgoing)"

# Allow SSH first! Critical!
echo -e "${YELLOW}Allowing SSH...${NC}"
if [[ "$SSH_PORT" == "22" ]]; then
    ufw allow OpenSSH >/dev/null 2>&1
    log "Allowed OpenSSH (port 22)"
else
    ufw allow "$SSH_PORT/tcp" comment "SSH" >/dev/null 2>&1
    log "Allowed SSH on port $SSH_PORT"
fi

# Allow HTTPS/VPN port
echo -e "${YELLOW}Allowing HTTPS/VPN...${NC}"
ufw allow 443/tcp comment "HTTPS/VPN" >/dev/null 2>&1
log "Allowed 443/tcp"

# Allow Remnawave API if detected
if [[ -n "$REMNAWAVE_PORT" ]]; then
    echo -e "${YELLOW}Allowing Remnawave API...${NC}"
    ufw allow "$REMNAWAVE_PORT/tcp" comment "Remnawave API" >/dev/null 2>&1
    log "Allowed $REMNAWAVE_PORT/tcp (Remnawave)"
fi

# Allow OpenVPN if installed
if $OPENVPN_INSTALLED; then
    echo -e "${YELLOW}Allowing OpenVPN...${NC}"
    ufw allow 1194/udp comment "OpenVPN" >/dev/null 2>&1
    log "Allowed 1194/udp (OpenVPN)"
fi

# Block ICMP (ping)
echo ""
echo -e "${YELLOW}Configuring ICMP blocking...${NC}"

BEFORE_RULES="/etc/ufw/before.rules"

if [[ ! -f "$BEFORE_RULES" ]]; then
    err "$BEFORE_RULES not found"
    exit 1
fi

# Backup
BACKUP_FILE="${BEFORE_RULES}.backup.$(date +%Y%m%d%H%M%S)"
cp "$BEFORE_RULES" "$BACKUP_FILE"
log "Backup: $BACKUP_FILE"

# Replace ACCEPT with DROP for ICMP rules
# This handles both INPUT and FORWARD icmp rules
sed -i 's/-A ufw-before-input -p icmp --icmp-type destination-unreachable -j ACCEPT/-A ufw-before-input -p icmp --icmp-type destination-unreachable -j DROP/g' "$BEFORE_RULES"
sed -i 's/-A ufw-before-input -p icmp --icmp-type time-exceeded -j ACCEPT/-A ufw-before-input -p icmp --icmp-type time-exceeded -j DROP/g' "$BEFORE_RULES"
sed -i 's/-A ufw-before-input -p icmp --icmp-type parameter-problem -j ACCEPT/-A ufw-before-input -p icmp --icmp-type parameter-problem -j DROP/g' "$BEFORE_RULES"
sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/g' "$BEFORE_RULES"

sed -i 's/-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j DROP/g' "$BEFORE_RULES"
sed -i 's/-A ufw-before-forward -p icmp --icmp-type time-exceeded -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type time-exceeded -j DROP/g' "$BEFORE_RULES"
sed -i 's/-A ufw-before-forward -p icmp --icmp-type parameter-problem -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type parameter-problem -j DROP/g' "$BEFORE_RULES"
sed -i 's/-A ufw-before-forward -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP/g' "$BEFORE_RULES"

# Add source-quench DROP if not exists
if ! grep -q "icmp-type source-quench" "$BEFORE_RULES"; then
    # Add after the echo-request line in INPUT section
    sed -i '/-A ufw-before-input -p icmp --icmp-type echo-request/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$BEFORE_RULES"
fi

log "ICMP rules changed to DROP"

# Enable UFW
echo ""
echo -e "${YELLOW}Enabling UFW...${NC}"
ufw --force enable >/dev/null 2>&1
log "UFW enabled"

# Show status
echo ""
echo -e "${YELLOW}Current UFW status:${NC}"
ufw status verbose

# Validate SSH is still accessible
echo ""
echo -e "${YELLOW}Validating SSH access...${NC}"
if ufw status | grep -qE "$SSH_PORT/tcp|OpenSSH"; then
    log "SSH port $SSH_PORT is allowed"
else
    err "SSH port might not be allowed! Check ufw status!"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}            UFW Configured!            ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Keep this session open!${NC}"
echo -e "${YELLOW}Test new SSH connection before closing.${NC}"
echo ""
