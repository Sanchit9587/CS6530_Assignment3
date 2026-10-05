#!/usr/bin/env bash
#
# tr3-ikev2-capture.sh — TR-3: capture a FRESH IKEv2 establishment.
# Forces the existing SA down, starts a capture on udp/500, udp/4500
# and esp, brings the tunnel back up (fresh IKE_SA_INIT/IKE_AUTH),
# then stops the capture. Run on EITHER site (one PCAP is enough for
# D3/E3, but both sides may want their own copy).
#
# Usage: sudo ./tr3-ikev2-capture.sh <site-a|site-b>

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 1 || ( "$1" != "site-a" && "$1" != "site-b" ) ]] && {
  echo "Usage: sudo $0 <site-a|site-b>" >&2; exit 1; }

SITE_ARG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/config/${SITE_ARG}.env"
CAPTURE_SH="$REPO_ROOT/common/capture.sh"
SNAPSHOT_SH="$REPO_ROOT/common/status_snapshot.sh"
CONN_NAME="cs6530-site-to-site"

[[ ! -f "$ENV_FILE" ]] && { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

[[ -z "${WAN_IFACE:-}" || "$WAN_IFACE" == *XX* ]] && {
  echo "ERROR: WAN_IFACE missing/placeholder in $ENV_FILE." >&2; exit 1; }

OUT_DIR="$REPO_ROOT/captures/tr3-ikev2-handshake"
TS="$(date +%Y%m%d-%H%M%S)"
PCAP_FILE="$OUT_DIR/${TS}_${SITE_ARG}_tr3-ikev2.pcap"
mkdir -p "$OUT_DIR"

echo "[*] Bringing connection DOWN to force a fresh handshake next time it's up"
ipsec down "$CONN_NAME" 2>/dev/null || true
sleep 1

FILTER="udp port 500 or udp port 4500 or esp"
echo "[*] Starting capture on $WAN_IFACE (filter: $FILTER)"
TCPDUMP_PID="$("$CAPTURE_SH" start "$WAN_IFACE" "$FILTER" "$PCAP_FILE")"
sleep 1

echo "[*] Bringing connection UP (this is the fresh establishment to capture)"
if ! ipsec up "$CONN_NAME"; then
  "$CAPTURE_SH" stop "$TCPDUMP_PID"
  echo "ERROR: 'ipsec up' failed — check peer side is also ready." >&2
  exit 1
fi

sleep 3   # let a couple of ESP packets flow after establishment for TR-3's "subsequent ESP" requirement
echo "[*] Generating a little ESP traffic for the capture (ping, best-effort)..."
if [[ -n "${NETNS_NAME:-}" && -n "${PEER_HOST_IP:-}" ]]; then
  ip netns exec "$NETNS_NAME" ping -c 2 "$PEER_HOST_IP" >/dev/null 2>&1 || true
fi
sleep 1

"$CAPTURE_SH" stop "$TCPDUMP_PID"
echo "[*] Capture stopped."
echo

# --- Snapshot the resulting established state too (useful cross-reference) ---
"$SNAPSHOT_SH" "tr3-fresh-establishment-${SITE_ARG}" || true

# --- Optional: if tshark is available, give a quick packet-type breakdown ---
if command -v tshark &>/dev/null; then
  echo
  echo "[*] Quick IKEv2 exchange-type breakdown (tshark):"
  tshark -r "$PCAP_FILE" -Y "isakmp" -T fields -e frame.number -e isakmp.exchangetype \
    2>/dev/null | awk '{print "   frame "$1": exchange type "$2}' || true
  echo "    (2=IKE_SA_INIT, 35=IKE_AUTH — map against Wireshark's ISAKMP dissector)"
else
  echo "[*] tshark not installed — open the PCAP in Wireshark GUI and filter on 'isakmp'"
  echo "    to identify IKE_SA_INIT (exchange type 34/IKE_SA_INIT) and IKE_AUTH packets,"
  echo "    and filter on 'esp' for the subsequent protected traffic."
fi

echo
echo "== TR-3 complete =="
echo "Evidence saved: $PCAP_FILE"
echo "In your report (D3/E3): screenshot Wireshark with 'isakmp' filter showing"
echo "IKE_SA_INIT req/resp and IKE_AUTH req/resp, then 'esp' filter showing"
echo "subsequent protected packets. State the purpose of each exchange (Section 4)."