#!/usr/bin/env bash
#
# tr2-protected.sh — TR-2: Normal protected session.
# With the IKEv2 tunnel UP, repeat the exact same ping (same host,
# destination, team payload) as TR-1. Capture ESP on the WAN interface,
# snapshot statusall/xfrm state/policy, confirm the payload is NOT
# visible in plaintext, and surface the SPI for correlation with
# ip xfrm state.
#
# Usage: sudo ./tr2-protected.sh <site-a|site-b>

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

[[ ! -f "$ENV_FILE" ]] && { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in WAN_IFACE PEER_HOST_IP ROLL_NO_SITE_A ROLL_NO_SITE_B NETNS_NAME; do
  val="${!var}"
  if [[ -z "$val" || "$val" == *XXX* || "$val" == *YYY* ]]; then
    echo "ERROR: $var in $ENV_FILE is missing or still a placeholder ('$val')." >&2
    exit 1
  fi
done

# --- Precondition: IKE_SA + CHILD_SA must be UP for this to be meaningful ---
if ! ipsec statusall 2>/dev/null | grep -q "ESTABLISHED"; then
  echo "ERROR: no ESTABLISHED IKE_SA found. Run tunnel-up.sh on both machines first." >&2
  exit 1
fi
if ! ipsec statusall 2>/dev/null | grep -q "INSTALLED, TUNNEL"; then
  echo "ERROR: no INSTALLED CHILD_SA found. Run tunnel-up.sh on both machines first." >&2
  exit 1
fi

# --- Same payload-construction logic as TR-1 (must match exactly) ---
PAYLOAD_STR="${ROLL_NO_SITE_A}${ROLL_NO_SITE_B}"
PAYLOAD_STR="${PAYLOAD_STR:0:16}"
PAYLOAD_HEX="$(printf '%s' "$PAYLOAD_STR" | od -An -tx1 | tr -d ' \n')"

echo "[*] Team payload string : $PAYLOAD_STR  (same as TR-1)"
echo "[*] Capturing on        : $WAN_IFACE (filter: esp)"
echo "[*] Pinging             : $PEER_HOST_IP (inside $NETNS_NAME)"
echo

OUT_DIR="$REPO_ROOT/captures/tr2-protected"
TS="$(date +%Y%m%d-%H%M%S)"
PCAP_FILE="$OUT_DIR/${TS}_${SITE_ARG}_tr2-protected.pcap"
PING_LOG="$OUT_DIR/${TS}_${SITE_ARG}_tr2-ping.log"
mkdir -p "$OUT_DIR"

# --- Capture ESP only (this is the point of TR-2: no plaintext ICMP on WAN) ---
TCPDUMP_PID="$("$CAPTURE_SH" start "$WAN_IFACE" "esp" "$PCAP_FILE")"
echo "[*] tcpdump started (PID $TCPDUMP_PID), capturing to $PCAP_FILE"
sleep 1

echo "[*] Sending ping (same payload as TR-1)..."
ip netns exec "$NETNS_NAME" ping -c 4 -p "$PAYLOAD_HEX" "$PEER_HOST_IP" | tee "$PING_LOG"

"$CAPTURE_SH" stop "$TCPDUMP_PID"
echo "[*] Capture stopped."
echo

# --- Snapshot statusall + xfrm state + xfrm policy (FR-6 / TR-2 evidence) ---
"$SNAPSHOT_SH" "tr2-protected-${SITE_ARG}"

# --- Sanity check 1: payload must NOT appear in plaintext in the ESP capture ---
echo
echo "[*] Checking that the team payload is NOT visible in plaintext..."
if tcpdump -r "$PCAP_FILE" -A -n 2>/dev/null | grep -qi "$PAYLOAD_STR"; then
  echo "!! WARNING: payload string found in plaintext inside the ESP capture." >&2
  echo "!! This should NOT happen if the tunnel is actually protecting traffic." >&2
else
  echo "[OK] Payload not found in plaintext — traffic is ESP-protected, as expected."
fi

# --- Sanity check 2: extract SPI(s) seen on the wire, for correlation with xfrm state ---
echo
echo "[*] ESP SPI(s) observed in this capture (correlate with 'ip xfrm state' above):"
tcpdump -r "$PCAP_FILE" -nnv esp 2>/dev/null | grep -o "spi 0x[0-9a-f]*" | sort -u || \
  echo "    (none parsed — inspect $PCAP_FILE manually in Wireshark)"

echo
echo "== TR-2 complete =="
echo "Evidence saved:"
echo "   PCAP     : $PCAP_FILE"
echo "   Ping log : $PING_LOG"
echo "   Snapshot : captures/snapshots/ (statusall + xfrm state + xfrm policy)"
echo "Manually confirm in your report: the SPI above matches an SPI line in"
echo "the xfrm state snapshot, and no inner ICMP/payload is visible in the PCAP."