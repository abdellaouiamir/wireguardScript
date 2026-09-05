#!/usr/bin/env bash
#
# wg-del-client.sh — Remove a WireGuard client: deletes its peer block from
#                     the server config, hot-reloads the interface, and
#                     removes its local config/QR files.
#
# Usage:
#   sudo ./wg-del-client.sh <client_name>
#   sudo ./wg-del-client.sh --list
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — MUST match wg-add-client.sh
# ---------------------------------------------------------------------------
WG_IFACE="${WG_IFACE:-wg0}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_SERVER_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_CLIENTS_DIR="${WG_DIR}/clients"

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

list_clients() {
    echo "Registered clients (from ${WG_SERVER_CONF}):"
    grep -oE '^\[Peer\] # .+' "${WG_SERVER_CONF}" 2>/dev/null \
        | sed 's/^\[Peer\] # /  - /' \
        || echo "  (none found)"
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: sudo $0 <client_name>"
    echo "       sudo $0 --list"
    exit 1
fi

require_root
require_cmd wg
require_cmd wg-quick

[[ -f "${WG_SERVER_CONF}" ]] || die "Server config not found: ${WG_SERVER_CONF}"

if [[ "$1" == "--list" || "$1" == "-l" ]]; then
    list_clients
    exit 0
fi

CLIENT_NAME="$1"
[[ "${CLIENT_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Client name must be alphanumeric (with - or _)"

CLIENT_CONF="${WG_CLIENTS_DIR}/${CLIENT_NAME}.conf"
CLIENT_QR_PNG="${WG_CLIENTS_DIR}/${CLIENT_NAME}.png"

# ---------------------------------------------------------------------------
# Step 1: Confirm the peer actually exists in the server config
# ---------------------------------------------------------------------------
PEER_TAG="[Peer] # ${CLIENT_NAME}"

if ! grep -qxF "${PEER_TAG}" "${WG_SERVER_CONF}"; then
    echo "No peer tagged '# ${CLIENT_NAME}' found in ${WG_SERVER_CONF}."
    echo
    list_clients
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Show what will be removed and ask for confirmation
# ---------------------------------------------------------------------------
echo ">> The following peer block will be permanently removed from ${WG_SERVER_CONF}:"
echo "---------------------------------------------------------------"
awk -v tag="${PEER_TAG}" '
    $0 == tag { printing = 1 }
    printing  { print }
    printing && NF == 0 && NR > 1 && $0 != tag { exit }
' "${WG_SERVER_CONF}"
echo "---------------------------------------------------------------"

read -rp "Type the client name again to confirm deletion (${CLIENT_NAME}): " CONFIRM
if [[ "${CONFIRM}" != "${CLIENT_NAME}" ]]; then
    die "Confirmation did not match. Aborting — nothing was changed."
fi

# ---------------------------------------------------------------------------
# Step 3: Backup the server config before editing it
# ---------------------------------------------------------------------------
BACKUP="${WG_SERVER_CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "${WG_SERVER_CONF}" "${BACKUP}"
echo ">> Backed up server config to ${BACKUP}"

# ---------------------------------------------------------------------------
# Step 4: Remove the peer block from the server config
#
# The peer block looks like:
#   [Peer] # clientname
#   PublicKey = ...
#   PresharedKey = ...
#   AllowedIPs = ...
#   <blank line>
#
# We delete from the "[Peer] # clientname" line through the next blank
# line (or EOF), inclusive.
# ---------------------------------------------------------------------------
TMP_CONF=$(mktemp)
awk -v tag="${PEER_TAG}" '
    $0 == tag { skipping = 1; next }
    skipping && NF == 0 { skipping = 0; next }
    skipping { next }
    { print }
' "${WG_SERVER_CONF}" > "${TMP_CONF}"

# Sanity check: make sure we actually removed something and did not
# accidentally wipe the whole file (e.g. malformed config).
if [[ ! -s "${TMP_CONF}" ]]; then
    rm -f "${TMP_CONF}"
    die "Refusing to write an empty server config — aborting. Backup is safe at ${BACKUP}."
fi

mv "${TMP_CONF}" "${WG_SERVER_CONF}"
chmod 600 "${WG_SERVER_CONF}"
echo ">> Peer '${CLIENT_NAME}' removed from ${WG_SERVER_CONF}"

# ---------------------------------------------------------------------------
# Step 5: Hot-reload the running interface, if it's up
# ---------------------------------------------------------------------------
if wg show "${WG_IFACE}" >/dev/null 2>&1; then
    echo ">> Reloading live interface ${WG_IFACE} via syncconf..."
    STRIPPED=$(mktemp)
    wg-quick strip "${WG_IFACE}" > "${STRIPPED}"
    wg syncconf "${WG_IFACE}" "${STRIPPED}"
    rm -f "${STRIPPED}"
    echo ">> ${WG_IFACE} reloaded — peer disconnected immediately, no restart needed."
else
    echo ">> ${WG_IFACE} is not currently running (change will apply on next start)."
fi

# ---------------------------------------------------------------------------
# Step 6: Remove the client's local files (config + QR image)
# ---------------------------------------------------------------------------
removed_any=0
for f in "${CLIENT_CONF}" "${CLIENT_QR_PNG}"; do
    if [[ -f "${f}" ]]; then
        rm -f "${f}"
        echo ">> Removed ${f}"
        removed_any=1
    fi
done
[[ "${removed_any}" -eq 1 ]] || echo ">> No local client files found to remove (already cleaned up, or never generated)."

echo
echo "=================================================================="
echo " Client '${CLIENT_NAME}' has been removed."
echo " Server config backup kept at: ${BACKUP}"
echo "=================================================================="
