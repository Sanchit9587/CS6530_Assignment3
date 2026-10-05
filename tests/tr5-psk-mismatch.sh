#!/usr/bin/env bash
#
# tr5-psk-mismatch.sh — TR-5: PSK authentication failure.
# Only ONE side runs this (coordinate who). Swaps the roll-number
# order in ITS OWN ipsec.secrets only, demonstrates auth failure,
# then restores the correct PSK and verifies.
#
# Usage:
#   sudo ./tr5-psk-mismatch.sh <site-a|site-b> break
#   sudo ./tr5-psk-mismatch.sh <site-a|site-b> restore

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 2 || ( "$1" != "site-a" && "$1" != "site-b" ) || ( "$2" != "break" && "$2" != "restore" ) ]] && {
  echo "Usage: sudo $0 <site-a|site-b> <break|restore>" >&2; exit 1; }

SITE_ARG="$1"
MODE="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/config/${SITE_ARG}.env"
CAPTURE_SH="$REPO_ROOT/common/capture.sh"
SNAPSHOT_SH="$REPO_ROOT/common/status_snapshot.sh"
CONN_NAME="cs6530-site-to-site"

# shellcheck disable=SC1090
source "$ENV_FILE"

write_secrets() {
  local psk="$1"
  sed -e "s|{{MY_WAN_IP}}|${MY_WAN_IP}|g" \
      -e "s|{{PEER_WAN_IP}}|${PEER_WAN_IP}|g" \
      -e "s|{{PSK}}|${psk}|g" \
      "$REPO_ROOT/config/ipsec.secrets.template" > /etc/ipsec.secrets
  chmod 600 /etc/ipsec.secrets
}

restart_and_attempt() {
  systemctl restart strongswan-starter
  sleep 2
  set +e
  ipsec up "$CONN_NAME"
  UP_RESULT=$?
  set -e
  return $UP_RESULT
}

OUT_DIR="$REPO_ROOT/captures/tr5-psk-mismatch"
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

ROLL_A_UPPER="$(echo "$ROLL_NO_SITE_A" | tr '[:lower:]' '[:upper:]')"
ROLL_B_UPPER="$(echo "$ROLL_NO_SITE_B" | tr '[:lower:]' '[:upper:]')"
CORRECT_PSK="${ROLL_A_UPPER}${ROLL_B_UPPER}${PSK_SUFFIX}"
SWAPPED_PSK="${ROLL_B_UPPER}${ROLL_A_UPPER}${PSK_SUFFIX}"   # roll numbers swapped = wrong PSK

if [[ "$MODE" == "break" ]]; then
  echo "[*] Correct PSK : $CORRECT_PSK"
  echo "[*] Swapped PSK (this side only): $SWAPPED_PSK"
  write_secrets "$SWAPPED_PSK"
  echo "[*] Wrote mismatched PSK to /etc/ipsec.secrets (this side only)"

  PCAP_FILE="$OUT_DIR/${TS}_${SITE_ARG}_tr5-psk-mismatch.pcap"
  TCPDUMP_PID="$("$CAPTURE_SH" start "$WAN_IFACE" "udp port 500 or udp port 4500" "$PCAP_FILE")"
  sleep 1

  echo "[*] Attempting 'ipsec up' (expected to FAIL — authentication mismatch)..."
  if restart_and_attempt; then
    echo "!! UNEXPECTED: ipsec up reported success despite PSK mismatch." >&2
  else
    echo "[CONFIRMED] ipsec up failed, as expected for a PSK mismatch."
  fi
  sleep 2
  "$CAPTURE_SH" stop "$TCPDUMP_PID"

  "$SNAPSHOT_SH" "tr5-psk-mismatch-break-${SITE_ARG}"

  echo
  echo "[*] Checking strongSwan logs for an authentication-failure indication..."
  journalctl -u strongswan-starter --since "1 minute ago" 2>/dev/null | grep -i "auth\|psk\|verif" | tail -10 || \
    echo "    (journalctl unavailable — check 'ipsec statusall' / syslog manually for AUTHENTICATION_FAILED)"

  echo
  echo "== TR-5 'break' complete =="
  echo "Evidence: $PCAP_FILE, captures/snapshots/*tr5-psk-mismatch-break-${SITE_ARG}*"
  echo "Next: coordinate with peer for their-side evidence, then run:"
  echo "   sudo $0 $SITE_ARG restore"

elif [[ "$MODE" == "restore" ]]; then
  echo "[*] Restoring correct PSK: $CORRECT_PSK"
  write_secrets "$CORRECT_PSK"
  if restart_and_attempt; then
    sleep 2
    "$SNAPSHOT_SH" "tr5-restored-${SITE_ARG}"
    if ipsec statusall | grep -q "ESTABLISHED" && ipsec statusall | grep -q "INSTALLED, TUNNEL"; then
      echo "[VERIFIED] IKE_SA + CHILD_SA re-established after restoring correct PSK."
    else
      echo "!! Restore ran but ESTABLISHED/INSTALLED not both seen — check peer side." >&2
    fi
  else
    echo "ERROR: restore failed — confirm peer also has correct PSK." >&2
    exit 1
  fi
  echo
  echo "== TR-5 'restore' complete (FR-8 satisfied) =="
fi