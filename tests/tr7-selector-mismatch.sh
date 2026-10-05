#!/usr/bin/env bash
#
# tr7-selector-mismatch.sh — TR-7: Traffic-selector mismatch.
# Only ONE side runs this. Changes its OWN subnet declaration to a
# wrong value, generates traffic, and gathers evidence to help you
# classify the effect as connectivity failure, protection failure,
# or both (classification needs your judgment on the output below —
# this script does not auto-classify, since both failure flavors
# produce overlapping symptoms worth inspecting by hand).
#
# Usage:
#   sudo ./tr7-selector-mismatch.sh <site-a|site-b> break
#   sudo ./tr7-selector-mismatch.sh <site-a|site-b> restore

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
WRONG_SUBNET="10.9.0.0/24"   # a subnet that does not match the namespace's real IP

# shellcheck disable=SC1090
source "$ENV_FILE"
CORRECT_SUBNET="$MY_SUBNET"

render_conf() {
  local my_subnet_value="$1"
  sed -e "s|{{MY_WAN_IP}}|${MY_WAN_IP}|g" \
      -e "s|{{PEER_WAN_IP}}|${PEER_WAN_IP}|g" \
      -e "s|{{MY_SUBNET}}|${my_subnet_value}|g" \
      -e "s|{{PEER_SUBNET}}|${PEER_SUBNET}|g" \
      -e "s|{{IKE_PROPOSAL}}|${IKE_PROPOSAL}|g" \
      -e "s|{{ESP_PROPOSAL}}|${ESP_PROPOSAL}|g" \
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

OUT_DIR="$REPO_ROOT/captures/tr7-selector-mismatch"
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

if [[ "$MODE" == "break" ]]; then
  echo "[*] Correct subnet declaration : $CORRECT_SUBNET"
  echo "[*] Wrong subnet declaration (this side's leftsubnet only): $WRONG_SUBNET"
  render_conf "$WRONG_SUBNET"

  restart_and_attempt || true
  sleep 2

  "$SNAPSHOT_SH" "tr7-selector-mismatch-break-${SITE_ARG}"

  echo
  echo "[*] Testing plain IP reachability (namespace IP is still really $CORRECT_SUBNET,"
  echo "    only the IPsec *policy* now claims $WRONG_SUBNET)..."
  PCAP_FILE="$OUT_DIR/${TS}_${SITE_ARG}_tr7-selector-mismatch.pcap"
  TCPDUMP_PID="$("$CAPTURE_SH" start "$WAN_IFACE" "icmp or esp" "$PCAP_FILE")"
  sleep 1
  ip netns exec "$NETNS_NAME" ping -c 4 -W 2 "$PEER_HOST_IP" || echo "(ping reported failure/loss — expected, keep reading)"
  sleep 1
  "$CAPTURE_SH" stop "$TCPDUMP_PID"

  echo
  echo "== Evidence gathered — classify by inspecting the following =="
  echo "1) ip xfrm policy (in the snapshot above): does a policy exist matching"
  echo "   $CORRECT_SUBNET traffic, or only $WRONG_SUBNET (which no real packet matches)?"
  echo "2) The capture $PCAP_FILE: did ICMP leave in PLAINTEXT (policy didn't match,"
  echo "   so XFRM never applied ESP — a PROTECTION failure, traffic still physically"
  echo "   reaches the peer unencrypted) or did packets fail to leave at all"
  echo "   (CONNECTIVITY failure)? Check both the pcap and the ping result above."
  echo "3) Record your classification (connectivity / protection / both) with this"
  echo "   evidence in your report, per TR-7's requirement."
  echo
  echo "Evidence: $PCAP_FILE, captures/snapshots/*tr7-selector-mismatch-break-${SITE_ARG}*"
  echo "Next: coordinate with peer for their-side evidence, then run:"
  echo "   sudo $0 $SITE_ARG restore"

elif [[ "$MODE" == "restore" ]]; then
  echo "[*] Restoring correct subnet: $CORRECT_SUBNET"
  render_conf "$CORRECT_SUBNET"
  if restart_and_attempt; then
    sleep 2
    "$SNAPSHOT_SH" "tr7-restored-${SITE_ARG}"
    if ipsec statusall | grep -q "ESTABLISHED" && ipsec statusall | grep -q "INSTALLED, TUNNEL"; then
      echo "[VERIFIED] IKE_SA + CHILD_SA re-established after restoring correct subnet."
    else
      echo "!! Restore ran but ESTABLISHED/INSTALLED not both seen — check peer side." >&2
    fi
  else
    echo "ERROR: restore failed." >&2
    exit 1
  fi
  echo
  echo "== TR-7 'restore' complete (FR-8 satisfied) =="
fi