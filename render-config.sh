#!/usr/bin/env bash
#
# render-config.sh — reads config/<site>.env, substitutes values into
# the templates in config/, and writes the real strongSwan config
# files to /etc/ipsec.secrets (and later /etc/ipsec.conf in FR3).
#
# Usage:
#   sudo ./render-config.sh site-a
#   sudo ./render-config.sh site-b

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo (writes to /etc/)." >&2; exit 1; }
[[ $# -ne 1 || ( "$1" != "site-a" && "$1" != "site-b" ) ]] && {
  echo "Usage: sudo $0 <site-a|site-b>" >&2; exit 1; }

SITE_ARG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/config/${SITE_ARG}.env"
SECRETS_TEMPLATE="$SCRIPT_DIR/config/ipsec.secrets.template"
CONF_TEMPLATE="$SCRIPT_DIR/config/ipsec.conf.template"

[[ ! -f "$ENV_FILE" ]] && { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

# --- refuse to run with unfilled placeholders ---
for var in MY_WAN_IP PEER_WAN_IP ROLL_NO_SITE_A ROLL_NO_SITE_B; do
  val="${!var}"
  if [[ "$val" == *XXX* || "$val" == *YYY* ]]; then
    echo "ERROR: $var in $ENV_FILE still looks like a placeholder ('$val')." >&2
    exit 1
  fi
done

# --- FR-2: build PSK in fixed Site-A then Site-B order, UPPER CASE ---
ROLL_A_UPPER="$(echo "$ROLL_NO_SITE_A" | tr '[:lower:]' '[:upper:]')"
ROLL_B_UPPER="$(echo "$ROLL_NO_SITE_B" | tr '[:lower:]' '[:upper:]')"
PSK="${ROLL_A_UPPER}${ROLL_B_UPPER}${PSK_SUFFIX}"

echo "[*] Constructed PSK: $PSK"
echo "    (verify this matches on BOTH machines before bringing up the tunnel)"

# --- render ipsec.secrets ---
sed -e "s|{{MY_WAN_IP}}|${MY_WAN_IP}|g" \
    -e "s|{{PEER_WAN_IP}}|${PEER_WAN_IP}|g" \
    -e "s|{{PSK}}|${PSK}|g" \
    "$SECRETS_TEMPLATE" > /etc/ipsec.secrets

chmod 600 /etc/ipsec.secrets
echo "[*] Wrote /etc/ipsec.secrets (mode 600)"

# --- FR-3/FR-4: render ipsec.conf (traffic selectors + IKE/ESP proposals) ---
if [[ -f /etc/ipsec.conf && ! -f /etc/ipsec.conf.orig-backup ]]; then
  cp /etc/ipsec.conf /etc/ipsec.conf.orig-backup
  echo "[*] Backed up existing /etc/ipsec.conf -> /etc/ipsec.conf.orig-backup"
fi

sed -e "s|{{MY_WAN_IP}}|${MY_WAN_IP}|g" \
    -e "s|{{PEER_WAN_IP}}|${PEER_WAN_IP}|g" \
    -e "s|{{MY_SUBNET}}|${MY_SUBNET}|g" \
    -e "s|{{PEER_SUBNET}}|${PEER_SUBNET}|g" \
    -e "s|{{IKE_PROPOSAL}}|${IKE_PROPOSAL}|g" \
    -e "s|{{ESP_PROPOSAL}}|${ESP_PROPOSAL}|g" \
    "$CONF_TEMPLATE" > /etc/ipsec.conf

echo "[*] Wrote /etc/ipsec.conf"
echo "    traffic selectors : ${MY_SUBNET} <=> ${PEER_SUBNET}"
echo "    IKE proposal       : ${IKE_PROPOSAL}"
echo "    ESP proposal       : ${ESP_PROPOSAL}"
echo
echo "== FR2/FR3/FR4 config render complete for $SITE_ARG =="
echo "Next: on BOTH machines, run:"
echo "   sudo ipsec restart"
echo "   sudo ipsec up cs6530-site-to-site"
echo "Then verify with: sudo ipsec statusall"