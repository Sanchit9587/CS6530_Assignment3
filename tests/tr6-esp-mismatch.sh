#!/usr/bin/env bash
#
# tr6-esp-mismatch.sh — TR-6: ESP proposal mismatch.
# Only ONE side runs this. Sets an incompatible ESP proposal on its
# own side only. Expected: IKE_SA (control plane) still establishes,
# but CHILD_SA (data plane) fails to install — demonstrating the
# IKE vs CHILD_SA distinction.
#
# Usage:
#   sudo ./tr6-esp-mismatch.sh <site-a|site-b> break
#   sudo ./tr6-esp-mismatch.sh <site-a|site-b> restore

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
WRONG_ESP="aes128-sha1!"   # strict, incompatible ESP proposal

# shellcheck disable=SC1090
source "$ENV_FILE"
CORRECT_ESP="$ESP_PROPOSAL"

render_conf() {
  local esp_value="$1"
  sed -e "s|{{MY_WAN_IP}}|${MY_WAN_IP}|g" \
      -e "s|{{PEER_WAN_IP}}|${PEER_WAN_IP}|g" \
      -e "s|{{MY_SUBNET}}|${MY_SUBNET}|g" \
      -e "s|{{PEER_SUBNET}}|${PEER_SUBNET}|g" \
      -e "s|{{IKE_PROPOSAL}}|${IKE_PROPOSAL}|g" \
      -e "s|{{ESP_PROPOSAL}}|${esp_value}|g" \
      "$REPO_ROOT/config/ipsec.conf.template" > /etc/ipsec.conf
}

restart_and_attempt() {
  ipsec stop 2>/dev/null || true
  pkill -9 charon 2>/dev/null || true
  rm -f /var/run/charon.pid /var/run/starter.charon.pid 2>/dev/null || true
  sleep 1
  ipsec start
  sleep 2
  set +e
  ipsec up "$CONN_NAME"
  UP_RESULT=$?
  set -e
  return $UP_RESULT
}

OUT_DIR="$REPO_ROOT/captures/tr6-esp-mismatch"
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

if [[ "$MODE" == "break" ]]; then
  echo "[*] Correct ESP proposal : $CORRECT_ESP"
  echo "[*] Mismatched ESP proposal (this side only): $WRONG_ESP"
  render_conf "$WRONG_ESP"

  PCAP_FILE="$OUT_DIR/${TS}_${SITE_ARG}_tr6-esp-mismatch.pcap"
  TCPDUMP_PID="$("$CAPTURE_SH" start "$WAN_IFACE" "udp port 500 or udp port 4500 or esp" "$PCAP_FILE")"
  sleep 1

  echo "[*] Attempting 'ipsec up'..."
  restart_and_attempt || true
  sleep 2
  "$CAPTURE_SH" stop "$TCPDUMP_PID"

  "$SNAPSHOT_SH" "tr6-esp-mismatch-break-${SITE_ARG}"

  echo
  IKE_UP=false
  CHILD_UP=false
  ipsec statusall | grep -q "ESTABLISHED" && IKE_UP=true
  ipsec statusall | grep -q "INSTALLED, TUNNEL" && CHILD_UP=true

  echo "[*] IKE_SA established?   $IKE_UP"
  echo "[*] CHILD_SA installed?   $CHILD_UP"
  if $IKE_UP && ! $CHILD_UP; then
    echo "[AS EXPECTED] Control-plane IKE_SA succeeded, but data-plane CHILD_SA failed"
    echo "              — this isolates the fault to ESP/CHILD_SA negotiation, not IKE auth."
  elif ! $IKE_UP; then
    echo "!! IKE_SA also failed — unexpected for an ESP-only mismatch, check ipsec.conf." >&2
  else
    echo "!! UNEXPECTED: CHILD_SA installed despite ESP mismatch — check config." >&2
  fi

  echo
  echo "== TR-6 'break' complete =="
  echo "Evidence: $PCAP_FILE, captures/snapshots/*tr6-esp-mismatch-break-${SITE_ARG}*"
  echo "Next: coordinate with peer for their-side evidence, then run:"
  echo "   sudo $0 $SITE_ARG restore"

elif [[ "$MODE" == "restore" ]]; then
  echo "[*] Restoring correct ESP proposal: $CORRECT_ESP"
  render_conf "$CORRECT_ESP"
  if restart_and_attempt; then
    sleep 2
    "$SNAPSHOT_SH" "tr6-restored-${SITE_ARG}"
    if ipsec statusall | grep -q "ESTABLISHED" && ipsec statusall | grep -q "INSTALLED, TUNNEL"; then
      echo "[VERIFIED] IKE_SA + CHILD_SA re-established after restoring correct ESP proposal."
    else
      echo "!! Restore ran but ESTABLISHED/INSTALLED not both seen — check peer side." >&2
    fi
  else
    echo "ERROR: restore failed." >&2
    exit 1
  fi
  echo
  echo "== TR-6 'restore' complete (FR-8 satisfied) =="
fi