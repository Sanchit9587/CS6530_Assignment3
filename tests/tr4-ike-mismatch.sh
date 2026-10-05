#!/usr/bin/env bash
#
# tr4-ike-mismatch.sh — TR-4: IKE proposal mismatch.
# Only ONE side runs this (coordinate who, e.g. Student B). The other
# side just runs common/status_snapshot.sh at the same time to record
# their own view of the failure.
#
# Usage:
#   sudo ./tr4-ike-mismatch.sh <site-a|site-b> break     # introduce mismatch, capture failure
#   sudo ./tr4-ike-mismatch.sh <site-a|site-b> restore   # revert to correct proposal, re-verify

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
WRONG_IKE="aes128-sha256-modp2048!"   # deliberately mismatched proposal per assignment TR-4

[[ ! -f "$ENV_FILE" ]] && { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
CORRECT_IKE="$IKE_PROPOSAL"   # the value already in the .env, assumed correct (aes256-...)

render_conf() {
  local ike_value="$1"
  sed -e "s|{{MY_WAN_IP}}|${MY_WAN_IP}|g" \
      -e "s|{{PEER_WAN_IP}}|${PEER_WAN_IP}|g" \
      -e "s|{{MY_SUBNET}}|${MY_SUBNET}|g" \
      -e "s|{{PEER_SUBNET}}|${PEER_SUBNET}|g" \
      -e "s|{{IKE_PROPOSAL}}|${ike_value}|g" \
      -e "s|{{ESP_PROPOSAL}}|${ESP_PROPOSAL}|g" \
      "$REPO_ROOT/config/ipsec.conf.template" > /etc/ipsec.conf
}

OUT_DIR="$REPO_ROOT/captures/tr4-ike-mismatch"
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

if [[ "$MODE" == "break" ]]; then
  echo "[*] Current (correct) IKE proposal : $CORRECT_IKE"
  echo "[*] Introducing MISMATCHED proposal : $WRONG_IKE"
  render_conf "$WRONG_IKE"
  echo "[*] Wrote /etc/ipsec.conf with mismatched IKE proposal"

  ipsec down "$CONN_NAME" 2>/dev/null || true
  systemctl restart strongswan-starter
  sleep 2

  PCAP_FILE="$OUT_DIR/${TS}_${SITE_ARG}_tr4-ike-mismatch.pcap"
  TCPDUMP_PID="$("$CAPTURE_SH" start "$WAN_IFACE" "udp port 500 or udp port 4500" "$PCAP_FILE")"
  sleep 1

  echo "[*] Attempting 'ipsec up' (expected to FAIL — proposal mismatch)..."
  set +e
  ipsec up "$CONN_NAME"
  UP_RESULT=$?
  set -e

  sleep 2
  "$CAPTURE_SH" stop "$TCPDUMP_PID"

  "$SNAPSHOT_SH" "tr4-ike-mismatch-break-${SITE_ARG}"

  echo
  if [[ $UP_RESULT -ne 0 ]] || ! ipsec statusall | grep -q "ESTABLISHED"; then
    echo "[CONFIRMED] IKE_SA did NOT establish — IKE_SA_INIT proposal negotiation failed."
  else
    echo "!! UNEXPECTED: IKE_SA appears ESTABLISHED despite mismatch — check config." >&2
  fi

  # --- classify: does ordinary (unprotected) reachability survive? ---
  echo
  echo "[*] Testing ordinary IP reachability (no IPsec) to classify the effect..."
  if ip netns exec "$NETNS_NAME" ping -c 2 -W 2 "$PEER_HOST_IP" &>/dev/null; then
    echo "[*] Plain ping SUCCEEDED -> connectivity intact, this is a PROTECTION failure only."
  else
    echo "[*] Plain ping FAILED -> routing/connectivity itself also broken (check FR1 setup,"
    echo "    this would be unusual for an IKE-only mismatch and worth double-checking)."
  fi

  echo
  echo "== TR-4 'break' complete =="
  echo "Evidence: $PCAP_FILE, captures/snapshots/*tr4-ike-mismatch-break-${SITE_ARG}*"
  echo "Next: coordinate with peer, record their evidence too, then run:"
  echo "   sudo $0 $SITE_ARG restore"

elif [[ "$MODE" == "restore" ]]; then
  echo "[*] Restoring correct IKE proposal: $CORRECT_IKE"
  render_conf "$CORRECT_IKE"
  systemctl restart strongswan-starter
  sleep 2

  echo "[*] Bringing connection back up..."
  if ipsec up "$CONN_NAME"; then
    sleep 2
    "$SNAPSHOT_SH" "tr4-restored-${SITE_ARG}"
    if ipsec statusall | grep -q "ESTABLISHED" && ipsec statusall | grep -q "INSTALLED, TUNNEL"; then
      echo "[VERIFIED] IKE_SA + CHILD_SA re-established after restoring correct proposal."
    else
      echo "!! Restore ran but ESTABLISHED/INSTALLED not both seen — check peer side too." >&2
    fi
  else
    echo "ERROR: restore failed — confirm peer also has the correct proposal and is reachable." >&2
    exit 1
  fi
  echo
  echo "== TR-4 'restore' complete (FR-8 satisfied for this test) =="
fi