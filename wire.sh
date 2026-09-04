#!/usr/bin/env bash
#
# wg-add-client.sh — Create a new WireGuard client config and register it
#                     with the server. Creates the server config if missing.
#
# Usage:
#   sudo ./wg-add-client.sh <client_name> [server_public_ip_or_host]
#
# Example:
#   sudo ./wg-add-client.sh alice vpn.example.com
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (edit to taste, or override via environment variables)
# ---------------------------------------------------------------------------
WG_IFACE="${WG_IFACE:-wg0}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_PORT="${WG_PORT:-51820}"
WG_SERVER_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_CLIENTS_DIR="${WG_DIR}/clients"

# Server VPN-internal address / subnet (the network wg0 will live on)
WG_SERVER_VPN_IP="${WG_SERVER_VPN_IP:-10.10.0.1}"
WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-24}"          # /24 -> 10.10.0.0/24
WG_NETWORK="${WG_NETWORK:-10.10.0.0/${WG_SUBNET_CIDR}}"

# DNS pushed to clients
WG_CLIENT_DNS="${WG_CLIENT_DNS:-1.1.1.1}"

# Egress interface for NAT (used only when creating a brand-new server conf)
EGRESS_IFACE="${EGRESS_IFACE:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"
EGRESS_IFACE="${EGRESS_IFACE:-eth0}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "Error: $*" >&2; exit 1; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root (try: sudo $0 ...)"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found. Install wireguard-tools."
}

# Find the next free client IP in WG_NETWORK by scanning existing AllowedIPs
next_free_ip() {
    local base network_prefix used_ips candidate i

    network_prefix="${WG_NETWORK%.*}"   # e.g. "10.10.0" from "10.10.0.0/24"

    # Collect last-octet of every AllowedIPs entry already in the server conf
    used_ips=$(grep -oE 'AllowedIPs *= *[0-9.]+' "${WG_SERVER_CONF}" 2>/dev/null \
        | awk -F. '{print $NF}' | tr -d '\r' || true)

    for i in $(seq 2 254); do
        if ! grep -qx "${i}" <<< "${used_ips}"; then
            echo "${network_prefix}.${i}"
            return 0
        fi
    done

    die "No free IP addresses left in ${WG_NETWORK}"
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: sudo $0 <client_name> [server_public_ip_or_host]"
    exit 1
fi

CLIENT_NAME="$1"
[[ "${CLIENT_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Client name must be alphanumeric (with - or _)"

SERVER_ENDPOINT_HOST="${2:-}"

require_root
require_cmd wg
require_cmd wg-quick

mkdir -p "${WG_DIR}" "${WG_CLIENTS_DIR}"
chmod 700 "${WG_DIR}" "${WG_CLIENTS_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Create server config + keys if they don't exist yet
# ---------------------------------------------------------------------------
if [[ ! -f "${WG_SERVER_CONF}" ]]; then
    echo ">> No server config found at ${WG_SERVER_CONF}. Creating one..."

    if [[ -z "${SERVER_ENDPOINT_HOST}" ]]; then
        # Try to auto-detect the public IP; fall back to asking the user.
        SERVER_ENDPOINT_HOST=$(curl -fsSL https://api.ipify.org 2>/dev/null || true)
        if [[ -z "${SERVER_ENDPOINT_HOST}" ]]; then
            die "Server public IP/host not provided and could not be auto-detected. Re-run with: $0 ${CLIENT_NAME} <server_ip_or_host>"
        fi
        echo ">> Auto-detected public endpoint: ${SERVER_ENDPOINT_HOST}"
    fi

    umask 077
    wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
    SERVER_PRIVATE_KEY=$(cat "${WG_DIR}/server_private.key")

    cat > "${WG_SERVER_CONF}" <<EOF
[Interface]
Address = ${WG_SERVER_VPN_IP}/${WG_SUBNET_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE; sysctl -w net.ipv4.ip_forward=1 >/dev/null
PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${EGRESS_IFACE} -j MASQUERADE; sysctl -w net.ipv4.ip_forward=0 >/dev/null

EOF
    chmod 600 "${WG_SERVER_CONF}"

    # Store the endpoint host for future client generations
    echo "${SERVER_ENDPOINT_HOST}" > "${WG_DIR}/server_endpoint.txt"

    # Enable IPv4 forwarding
    # if ! sysctl net.ipv4.ip_forward | grep -q ' = 1'; then
    #     sysctl -w net.ipv4.ip_forward=1 >/dev/null
    #     if ! grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
    #         echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    #     fi
    # fi

    echo ">> Server config created at ${WG_SERVER_CONF}"
    echo ">> Bring it up with: systemctl enable --now wg-quick@${WG_IFACE}"
else
    echo ">> Existing server config found at ${WG_SERVER_CONF}"
    if [[ -z "${SERVER_ENDPOINT_HOST}" ]]; then
        if [[ -f "${WG_DIR}/server_endpoint.txt" ]]; then
            SERVER_ENDPOINT_HOST=$(cat "${WG_DIR}/server_endpoint.txt")
        else
            die "Server endpoint host/IP not known. Re-run with: $0 ${CLIENT_NAME} <server_ip_or_host>"
        fi
    fi
fi

SERVER_PUBLIC_KEY=$(cat "${WG_DIR}/server_public.key" 2>/dev/null) \
    || die "Could not read ${WG_DIR}/server_public.key"

# ---------------------------------------------------------------------------
# Step 2: Bail out early if this client already exists
# ---------------------------------------------------------------------------
CLIENT_CONF="${WG_CLIENTS_DIR}/${CLIENT_NAME}.conf"
if [[ -f "${CLIENT_CONF}" ]]; then
    die "Client config already exists: ${CLIENT_CONF} (pick a different name or remove it first)"
fi
if grep -q "# ${CLIENT_NAME}\$" "${WG_SERVER_CONF}" 2>/dev/null; then
    die "A peer tagged '# ${CLIENT_NAME}' already exists in ${WG_SERVER_CONF}"
fi

# ---------------------------------------------------------------------------
# Step 3: Generate client keys + preshared key
# ---------------------------------------------------------------------------
umask 077
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "${CLIENT_PRIVATE_KEY}" | wg pubkey)
PRESHARED_KEY=$(wg genpsk)

CLIENT_VPN_IP=$(next_free_ip)
echo ">> Assigning client IP: ${CLIENT_VPN_IP}"

# ---------------------------------------------------------------------------
# Step 4: Append peer block to server config
# ---------------------------------------------------------------------------
{
    echo "[Peer] # ${CLIENT_NAME}"
    echo "PublicKey = ${CLIENT_PUBLIC_KEY}"
    echo "PresharedKey = ${PRESHARED_KEY}"
    echo "AllowedIPs = ${CLIENT_VPN_IP}/32"
    echo
} >> "${WG_SERVER_CONF}"

echo ">> Peer added to ${WG_SERVER_CONF}"

# ---------------------------------------------------------------------------
# Step 5: Write client config file
# ---------------------------------------------------------------------------
cat > "${CLIENT_CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_VPN_IP}/32
DNS = ${WG_CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = ${SERVER_ENDPOINT_HOST}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "${CLIENT_CONF}"

echo ">> Client config written to ${CLIENT_CONF}"

# ---------------------------------------------------------------------------
# Step 6: Hot-reload the running interface, if it's up
# ---------------------------------------------------------------------------
if wg show "${WG_IFACE}" >/dev/null 2>&1; then
    echo ">> Reloading live interface ${WG_IFACE} via syncconf..."
    STRIPPED=$(mktemp)
    wg-quick strip "${WG_IFACE}" > "${STRIPPED}"
    wg syncconf "${WG_IFACE}" "${STRIPPED}"
    rm -f "${STRIPPED}"
    echo ">> ${WG_IFACE} reloaded, no restart needed."
else
    echo ">> ${WG_IFACE} is not currently running."
    echo "   Start it with: systemctl enable --now wg-quick@${WG_IFACE}"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
echo "=================================================================="
echo " Client '${CLIENT_NAME}' created successfully"
echo " Config file: ${CLIENT_CONF}"
echo " VPN IP:      ${CLIENT_VPN_IP}"
echo "=================================================================="
if command -v qrencode >/dev/null 2>&1; then
    echo
    echo "Scan this QR code with the WireGuard mobile app:"
    qrencode -t ansi256utf8 < "${CLIENT_CONF}"
else
    echo "(Install 'qrencode' to also get a scannable QR code for mobile clients.)"
fi
