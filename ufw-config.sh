#!/bin/bash

# UFW Firewall Configuration Script
# Tested on: Ubuntu 18.04+, Debian 9+

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    err "Run this script as root"
    exit 1
fi

check_cmd() {
    command -v "$1" &>/dev/null || { err "Required command not found: $1"; exit 1; }
}

check_cmd sed
check_cmd grep
check_cmd ss
check_cmd awk

# Add UFW rule only if not already present (idempotent)
ufw_allow() {
    local rule="$1" comment="${2:-}"
    if ufw status 2>/dev/null | grep -q "ALLOW" && ufw status 2>/dev/null | grep "ALLOW" | grep -qF "${rule}"; then
        log "Already allowed: $rule (skipped)"
        return
    fi
    if [[ -n "$comment" ]]; then
        ufw allow "$rule" comment "$comment" >/dev/null 2>&1
    else
        ufw allow "$rule" >/dev/null 2>&1
    fi
    log "Allowed $rule"
}

if ! command -v ufw &>/dev/null; then
    warn "UFW not installed. Installing..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y ufw >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y ufw >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y ufw >/dev/null 2>&1
    else
        err "Cannot install UFW: unknown package manager"
        exit 1
    fi
    log "UFW installed"
fi

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}      UFW Firewall Configuration       ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# --- Detect SSH port ---
SSH_PORT=""
if [[ -f /etc/ssh/.custom_port ]]; then
    SSH_PORT=$(cat /etc/ssh/.custom_port 2>/dev/null)
fi
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(grep -E "^Port[[:space:]]" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
fi
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep -E "sshd|\"ssh\"" | grep -oE ':([0-9]+)' | head -1 | tr -d ':')
fi
SSH_PORT=${SSH_PORT:-22}
echo -e "SSH port detected: ${GREEN}$SSH_PORT${NC}"

# --- Detect OpenVPN ---
OPENVPN_INSTALLED=false
if command -v openvpn &>/dev/null || systemctl list-units --type=service 2>/dev/null | grep -q openvpn; then
    OPENVPN_INSTALLED=true
fi

# --- Detect Remnawave/Remnanode ports ---
REMNAWAVE_PORT=""
REMNAWAVE_EXTRA_PORTS=()
REMNAWAVE_PATHS=("/opt/remnanode/.env" "/opt/remnawave/.env")

for env_file in "${REMNAWAVE_PATHS[@]}"; do
    [[ -f "$env_file" ]] || continue
    if [[ -z "$REMNAWAVE_PORT" ]]; then
        p=$(grep -E "^NODE_PORT=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
        if [[ -n "$p" && "$p" =~ ^[0-9]+$ ]]; then
            REMNAWAVE_PORT="$p"
            echo -e "Remnanode port: ${GREEN}$REMNAWAVE_PORT${NC} (from $env_file)"
        fi
    fi
    for var in SELF_STEAL_PORT; do
        p=$(grep -E "^${var}=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
        if [[ -n "$p" && "$p" =~ ^[0-9]+$ ]]; then
            REMNAWAVE_EXTRA_PORTS+=("$p")
            echo -e "${var}: ${GREEN}$p${NC} (from $env_file)"
        fi
    done
done

# --- Detect Xray ports ---
XRAY_PORTS=()

# Helper: parse port values from xray config.json
_xray_ports_from_json() {
    local f="$1"
    [[ -f "$f" ]] || return
    if command -v jq &>/dev/null; then
        jq -r '(.inbounds // [])[].port | select(. != null) | if type == "number" then tostring else . end' "$f" 2>/dev/null
    else
        grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+'
        grep -oE '"port"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$f" 2>/dev/null | grep -oE '"[0-9][^"]*"' | tr -d '"'
    fi
}

# Helper: expand "80", "80-82", "80,81,82" to individual port numbers
_expand_port_spec() {
    local spec="$1"
    local part a b
    for part in ${spec//,/ }; do
        if [[ "$part" == *-* ]]; then
            a="${part%-*}"; b="${part#*-}"
            [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || continue
            for ((p=a; p<=b; p++)); do echo "$p"; done
        else
            [[ "$part" =~ ^[0-9]+$ ]] && echo "$part"
        fi
    done
}

# 1. From xray config.json
for cfg in "/etc/xray/config.json" "/usr/local/etc/xray/config.json"; do
    [[ -f "$cfg" ]] || continue
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        while IFS= read -r p; do
            [[ -n "$p" ]] && XRAY_PORTS+=("$p")
        done < <(_expand_port_spec "$spec")
    done < <(_xray_ports_from_json "$cfg")
    [[ ${#XRAY_PORTS[@]} -gt 0 ]] && break
done

# 2. From .env files (NODE_PORT, SELF_STEAL_PORT) — skip known Remnawave paths
_is_remnawave_path() {
    local f="$1"
    for rp in "${REMNAWAVE_PATHS[@]}"; do
        [[ "$f" == "$rp" ]] && return 0
    done
    return 1
}

while IFS= read -r env_file; do
    [[ -f "$env_file" ]] || continue
    _is_remnawave_path "$env_file" && continue
    grep -qE "^(XTLS_API_PORT|SELF_STEAL_PORT)=" "$env_file" 2>/dev/null || continue
    # NODE_PORT only from files that also have XTLS_API_PORT (to avoid random services)
    if grep -qE "^XTLS_API_PORT=" "$env_file" 2>/dev/null; then
        p=$(grep -E "^NODE_PORT=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
        [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && XRAY_PORTS+=("$p")
    fi
    p=$(grep -E "^SELF_STEAL_PORT=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
    [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && XRAY_PORTS+=("$p")
done < <(find /opt /root /etc /usr/local -maxdepth 3 -name ".env" -type f 2>/dev/null)

# 3. From Docker containers named/imaged as xray/v2ray
if command -v docker &>/dev/null; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="${line%% *}"; rest="${line#* }"
        if [[ "$name" =~ [xX]ray ]] || [[ "$rest" =~ [xX]ray ]] || [[ "$rest" =~ [vV]2ray ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && XRAY_PORTS+=("$p")
            done < <(docker port "$name" 2>/dev/null | grep -oE ':[0-9]+$' | tr -d ':')
        fi
    done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null)
fi

# Deduplicate, exclude already-handled ports (SSH, 443, Remnawave)
XRAY_PORTS_UNIQ=()
for p in "${XRAY_PORTS[@]}"; do
    [[ "$p" == "22" || "$p" == "$SSH_PORT" || "$p" == "443" ]] && continue
    [[ -n "$REMNAWAVE_PORT" && "$p" == "$REMNAWAVE_PORT" ]] && continue
    skip=false
    for u in "${XRAY_PORTS_UNIQ[@]}"; do [[ "$u" == "$p" ]] && { skip=true; break; }; done
    [[ "$skip" == false ]] && XRAY_PORTS_UNIQ+=("$p")
done

# --- Summary ---
echo ""
echo -e "${YELLOW}Will configure:${NC}"
echo "  [x] Allow SSH on port $SSH_PORT"
echo "  [x] Allow 443/tcp (HTTPS/VPN)"
if [[ ${#XRAY_PORTS_UNIQ[@]} -gt 0 ]]; then
    echo "  [x] Allow Xray: ${XRAY_PORTS_UNIQ[*]} (detected)"
else
    echo "  [ ] Xray: not detected"
fi
if [[ -n "$REMNAWAVE_PORT" ]]; then
    extra=""
    [[ ${#REMNAWAVE_EXTRA_PORTS[@]} -gt 0 ]] && extra=" + ${REMNAWAVE_EXTRA_PORTS[*]}"
    echo "  [x] Allow Remnawave: $REMNAWAVE_PORT/tcp${extra} (detected)"
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

read -rp "Continue? (y/n): " CONFIRM </dev/tty
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Cancelled"
    exit 0
fi
echo ""

# --- Apply ---
echo -e "${YELLOW}Setting default policies...${NC}"
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
log "Default policies set"

echo -e "${YELLOW}Allowing SSH...${NC}"
if [[ "$SSH_PORT" == "22" ]]; then
    ufw_allow "OpenSSH"
else
    ufw_allow "$SSH_PORT/tcp" "SSH"
fi

echo -e "${YELLOW}Allowing HTTPS/VPN...${NC}"
ufw_allow "443/tcp" "HTTPS/VPN"

if [[ ${#XRAY_PORTS_UNIQ[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Allowing Xray ports...${NC}"
    for p in "${XRAY_PORTS_UNIQ[@]}"; do
        ufw_allow "$p/tcp" "Xray"
        ufw_allow "$p/udp" "Xray"
    done
fi

if [[ -n "$REMNAWAVE_PORT" ]]; then
    echo -e "${YELLOW}Allowing Remnawave API...${NC}"
    ufw_allow "$REMNAWAVE_PORT/tcp" "Remnawave API"
fi

if $OPENVPN_INSTALLED; then
    echo -e "${YELLOW}Allowing OpenVPN...${NC}"
    ufw_allow "1194/udp" "OpenVPN"
fi

# --- Block ICMP ---
echo ""
echo -e "${YELLOW}Configuring ICMP blocking...${NC}"
BEFORE_RULES="/etc/ufw/before.rules"

if [[ ! -f "$BEFORE_RULES" ]]; then
    err "$BEFORE_RULES not found"
    exit 1
fi

ICMP_NEEDS_CHANGE=false
grep -q "icmp.*-j ACCEPT" "$BEFORE_RULES" && ICMP_NEEDS_CHANGE=true
grep -q "icmp-type source-quench" "$BEFORE_RULES" || ICMP_NEEDS_CHANGE=true

if [[ "$ICMP_NEEDS_CHANGE" == true ]]; then
    BACKUP_FILE="${BEFORE_RULES}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$BEFORE_RULES" "$BACKUP_FILE"
    log "Backup: $BACKUP_FILE"

    local_icmp_types=(destination-unreachable time-exceeded parameter-problem echo-request)
    for icmp_type in "${local_icmp_types[@]}"; do
        sed -i "s/-A ufw-before-input -p icmp --icmp-type ${icmp_type} -j ACCEPT/-A ufw-before-input -p icmp --icmp-type ${icmp_type} -j DROP/g" "$BEFORE_RULES"
        sed -i "s/-A ufw-before-forward -p icmp --icmp-type ${icmp_type} -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type ${icmp_type} -j DROP/g" "$BEFORE_RULES"
    done

    if ! grep -q "icmp-type source-quench" "$BEFORE_RULES"; then
        sed -i '/-A ufw-before-input -p icmp --icmp-type echo-request/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$BEFORE_RULES"
    fi

    log "ICMP rules set to DROP"
else
    log "ICMP already configured (skipped)"
fi

# --- Enable ---
echo ""
echo -e "${YELLOW}Enabling UFW...${NC}"
ufw --force enable >/dev/null 2>&1
log "UFW enabled"

echo ""
echo -e "${YELLOW}Current UFW status:${NC}"
ufw status verbose

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
