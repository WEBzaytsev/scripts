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

# Prompt for port
while true; do
    read -p "Enter new SSH port (1024-65535): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [[ "$NEW_PORT" -ge 1024 ]] && [[ "$NEW_PORT" -le 65535 ]]; then
        break
    else
        echo -e "${YELLOW}Invalid port. Enter a number between 1024 and 65535${NC}"
    fi
done

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

# Restart SSH
echo ""
echo -e "${YELLOW}Restarting SSH...${NC}"
if systemctl is-active --quiet sshd; then
    systemctl restart sshd
    echo -e "${GREEN}sshd restarted${NC}"
elif systemctl is-active --quiet ssh; then
    systemctl restart ssh
    echo -e "${GREEN}ssh restarted${NC}"
else
    service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
    echo -e "${GREEN}SSH service restarted${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Done! SSH now on port $NEW_PORT${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Keep this session open!${NC}"
echo -e "${YELLOW}Test new connection: ssh -p $NEW_PORT user@server${NC}"
echo ""

