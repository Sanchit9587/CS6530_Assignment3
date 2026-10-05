#!/usr/bin/env bash
#
# tunnel-up.sh — FR4: bring up the IKEv2 tunnel and confirm IKE_SA +
# CHILD_SA establishment. Run this on BOTH machines after render-config.sh
# has been run on both (ipsec.conf / ipsec.secrets must already be in place).
#
# Usage: sudo ./tunnel-up.sh

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }

CONN_NAME="cs6530-site-to-site"

echo "[*] Restarting strongSwan (charon daemon)"
ipsec restart
sleep 2

echo "[*] Bringing up connection: $CONN_NAME"
if ! ipsec up "$CONN_NAME"; then
  echo "ERROR: 'ipsec up' failed. Check /etc/ipsec.conf and /etc/ipsec.secrets," >&2
  echo "       and confirm the peer has also run render-config.sh + is reachable." >&2
  exit 1
fi

sleep 2

echo
echo "[*] Current status:"
ipsec statusall

echo
if ipsec statusall | grep -q "ESTABLISHED"; then
  echo "== IKE_SA ESTABLISHED =="
else
  echo "!! IKE_SA NOT established yet — check peer side and network reachability." >&2
fi

if ipsec statusall | grep -q "INSTALLED, TUNNEL"; then
  echo "== CHILD_SA INSTALLED (tunnel mode) =="
  echo
  echo "[*] ESP SPIs:"
  ipsec statusall | grep "ESP SPIs"
else
  echo "!! CHILD_SA not installed yet." >&2
fi