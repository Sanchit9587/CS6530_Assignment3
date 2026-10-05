#!/usr/bin/env bash
#
# tr8-boundary.sh — TR-8: Security-boundary observation.
# Captures the SAME protected ping simultaneously on the gateway's
# protected-side interface (plaintext expected) and the WAN interface
# (ESP expected), to show why the same flow looks different on each
# side of the gateway. Tunnel must already be up.
#
# Usage: sudo ./tr8-boundary.sh <site-a|site-b>

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 1 || ( "$1" != "site-a" && "$1" != "site-b" ) ]] && {
  echo "Usage: sudo $0 <site-a|site-b>" >&2; exit 1; }

SITE_ARG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/config/${SITE_ARG}.env"
CAPTURE_SH="$REPO_ROOT/common/capture.sh"

# shellcheck disable=SC1090
source "$ENV_FILE"

if ! ipsec statusall 2>/dev/null | grep -q "INSTALLED, TUNNEL"; then
  echo "ERROR: no INSTALLED CHILD_SA — bring the tunnel up first (FR4)." >&2
  exit 1
fi

OUT_DIR="$REPO_ROOT/captures/tr8-boundary"
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

PROTECTED_PCAP="$OUT_DIR/${TS}_${SITE_ARG}_tr8-protected-side.pcap"
WAN_PCAP="$OUT_DIR/${TS}_${SITE_ARG}_tr8-wan-side.pcap"

echo "[*] Protected-side interface : $VETH_HOST (should show PLAINTEXT ICMP)"
echo "[*] WAN interface            : $WAN_IFACE (should show ESP only)"
echo

PID_PROTECTED="$("$CAPTURE_SH" start "$VETH_HOST" "icmp" "$PROTECTED_PCAP")"
PID_WAN="$("$CAPTURE_SH" start "$WAN_IFACE" "icmp or esp" "$WAN_PCAP")"
sleep 1

echo "[*] Sending ping through the tunnel..."
ip netns exec "$NETNS_NAME" ping -c 4 "$PEER_HOST_IP"

sleep 1
"$CAPTURE_SH" stop "$PID_PROTECTED"
"$CAPTURE_SH" stop "$PID_WAN"

echo
echo "[*] Protected-side capture summary ($VETH_HOST):"
tcpdump -r "$PROTECTED_PCAP" -n 2>/dev/null

echo
echo "[*] WAN-side capture summary ($WAN_IFACE):"
tcpdump -r "$WAN_PCAP" -n 2>/dev/null

echo
echo "== TR-8 complete =="
echo "Evidence saved:"
echo "   Protected-side PCAP : $PROTECTED_PCAP  (expect: plaintext ICMP, inner 10.x.0.10 addrs)"
echo "   WAN-side PCAP        : $WAN_PCAP  (expect: ESP only, no ICMP visible)"
echo "In your report, explain: the gateway applies XFRM transform AFTER the packet"
echo "leaves the protected-side interface and BEFORE it reaches the WAN interface —"
echo "that's why the same flow looks different on each side."