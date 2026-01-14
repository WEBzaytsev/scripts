#!/bin/bash

# SSH Configuration Script
# Tested on: Ubuntu 18.04+, Debian 9+, CentOS 7+, Rocky Linux 8+

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Run this script as root${NC}"
    exit 1
fi

# Config file
SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ ! -f "$SSHD_CONFIG" ]]; then
    echo -e "${RED}Error: $SSHD_CONFIG not found${NC}"
    exit 1
fi

# Get current values
get_sshd_value() {
    grep -E "^${1}[[:space:]]" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | tail -1
}

# Get actual listening port from ss
get_listening_port() {
    ss -tlnp 2>/dev/null | grep -E "sshd|\"ssh\"" | grep -oE ':([0-9]+)' | head -1 | tr -d ':'
}

CONFIG_PORT=$(get_sshd_value "Port")
CONFIG_PORT=${CONFIG_PORT:-22}
LISTEN_PORT=$(get_listening_port)
LISTEN_PORT=${LISTEN_PORT:-unknown}
CURRENT_MAXAUTH=$(get_sshd_value "MaxAuthTries")
CURRENT_MAXSESS=$(get_sshd_value "MaxSessions")
CURRENT_MAXSTART=$(get_sshd_value "MaxStartups")

echo -e "${YELLOW}Current settings:${NC}"
echo "  Port (config): $CONFIG_PORT"
echo "  Port (actual): $LISTEN_PORT"
echo "  MaxAuthTries: ${CURRENT_MAXAUTH:-default}"
echo "  MaxSessions: ${CURRENT_MAXSESS:-default}"
echo "  MaxStartups: ${CURRENT_MAXSTART:-default}"
echo ""

# Use actual listening port for comparison
CURRENT_PORT="$LISTEN_PORT"
[[ "$CURRENT_PORT" == "unknown" ]] && CURRENT_PORT="$CONFIG_PORT"

# Warn if port was already changed
if [[ "$CURRENT_PORT" != "22" ]]; then
    echo -e "${RED}WARNING: SSH port was already changed to $CURRENT_PORT${NC}"
    echo -e "${RED}Running this script again will change it to a new port.${NC}"
    read -p "Are you sure you want to continue? (y/n): " WARN_CONFIRM
    if [[ "$WARN_CONFIRM" != "y" && "$WARN_CONFIRM" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi
    echo ""
fi

# Prompt for port
while true; do
    read -p "Enter new SSH port (1024-65535): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [[ "$NEW_PORT" -ge 1024 ]] && [[ "$NEW_PORT" -le 65535 ]]; then
        break
    else
        echo -e "${YELLOW}Invalid port. Enter a number between 1024 and 65535${NC}"
    fi
done

# Check if already configured (config + actually listening)
if [[ "$CONFIG_PORT" == "$NEW_PORT" ]] && \
   [[ "$LISTEN_PORT" == "$NEW_PORT" ]] && \
   [[ "$CURRENT_MAXAUTH" == "6" ]] && \
   [[ "$CURRENT_MAXSESS" == "4" ]] && \
   [[ "$CURRENT_MAXSTART" == "10:30:60" ]]; then
    echo ""
    echo -e "${GREEN}Already configured with these settings. Nothing to do.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Will apply:${NC}"
echo "  Port: $NEW_PORT"
echo "  MaxAuthTries: 6"
echo "  MaxSessions: 4"
echo "  MaxStartups: 10:30:60"
echo ""
read -p "Continue? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Cancelled"
    exit 0
fi

# Backup
BACKUP_FILE="${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
cp "$SSHD_CONFIG" "$BACKUP_FILE"
echo -e "${GREEN}Backup created: $BACKUP_FILE${NC}"

# Function to set config value
set_sshd_option() {
    local option="$1"
    local value="$2"
    
    # Remove all existing entries (commented and uncommented)
    sed -i "/^[#[:space:]]*${option}[[:space:]]/d" "$SSHD_CONFIG"
    
    # Add new value at the end
    echo "${option} ${value}" >> "$SSHD_CONFIG"
    echo -e "${GREEN}Set: ${option} ${value}${NC}"
}

# Apply settings
set_sshd_option "Port" "$NEW_PORT"
set_sshd_option "MaxAuthTries" "6"
set_sshd_option "MaxSessions" "4"
set_sshd_option "MaxStartups" "10:30:60"

# Save port marker for ufw-config.sh
echo "$NEW_PORT" > /etc/ssh/.custom_port
echo -e "${GREEN}Port marker saved for UFW script${NC}"

# Test config
echo ""
echo -e "${YELLOW}Testing SSH config...${NC}"
if sshd -t; then
    echo -e "${GREEN}Config syntax OK${NC}"
else
    echo -e "${RED}Config error! Restoring backup...${NC}"
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    exit 1
fi

# Firewall - UFW
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}Configuring UFW...${NC}"
    ufw allow "$NEW_PORT/tcp" comment "SSH"
    echo -e "${GREEN}UFW: port $NEW_PORT allowed${NC}"
fi

# Firewall - firewalld
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    echo -e "${YELLOW}Configuring firewalld...${NC}"
    firewall-cmd --permanent --add-port="$NEW_PORT/tcp"
    firewall-cmd --reload
    echo -e "${GREEN}firewalld: port $NEW_PORT allowed${NC}"
fi

# SELinux
if command -v semanage &>/dev/null && getenforce 2>/dev/null | grep -qi "enforcing"; then
    echo -e "${YELLOW}Configuring SELinux...${NC}"
    semanage port -a -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null || \
    semanage port -m -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null || true
    echo -e "${GREEN}SELinux: port $NEW_PORT allowed${NC}"
fi

# Disable ssh.socket if exists (overrides sshd_config port)
if systemctl is-enabled ssh.socket &>/dev/null; then
    echo -e "${YELLOW}Disabling ssh.socket (uses port from config)...${NC}"
    systemctl disable ssh.socket &>/dev/null || true
    systemctl stop ssh.socket &>/dev/null || true
    echo -e "${GREEN}ssh.socket disabled${NC}"
fi

# Restart SSH
echo ""
echo -e "${YELLOW}Restarting SSH...${NC}"
if systemctl list-units --type=service | grep -q "sshd.service"; then
    systemctl restart sshd
    echo -e "${GREEN}sshd restarted${NC}"
elif systemctl list-units --type=service | grep -q "ssh.service"; then
    systemctl restart ssh
    echo -e "${GREEN}ssh restarted${NC}"
else
    service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
    echo -e "${GREEN}SSH service restarted${NC}"
fi

# Validate SSH is listening on new port
echo ""
echo -e "${YELLOW}Validating...${NC}"
sleep 1
if ss -tlnp 2>/dev/null | grep -q ":$NEW_PORT"; then
    echo -e "${GREEN}SSH listening on port $NEW_PORT${NC}"
else
    echo -e "${RED}Warning: SSH may not be listening on port $NEW_PORT${NC}"
    echo -e "${YELLOW}Check manually: ss -tlnp | grep $NEW_PORT${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Done! SSH now on port $NEW_PORT${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Keep this session open!${NC}"
echo -e "${YELLOW}Test new connection: ssh -p $NEW_PORT user@server${NC}"
echo ""

