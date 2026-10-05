#!/usr/bin/env bash
#
# tr1-baseline.sh — TR-1: Baseline plaintext test.
# With IPsec NOT active, ping from this machine's protected-host
# namespace to the peer's, using a recognizable team-specific payload,
# while capturing ICMP on the WAN interface. Proves plaintext visibility
# before any protection is applied.
#
# Usage: sudo ./tr1-baseline.sh <site-a|site-b>

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 1 || ( "$1" != "site-a" && "$1" != "site-b" ) ]] && {
  echo "Usage: sudo $0 <site-a|site-b>" >&2; exit 1; }

SITE_ARG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/config/${SITE_ARG}.env"
CAPTURE_SH="$REPO_ROOT/common/capture.sh"

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

# --- Safety check: IPsec must NOT be active for a true baseline ---
if command -v ipsec &>/dev/null && ipsec statusall 2>/dev/null | grep -q "ESTABLISHED"; then
  echo "WARNING: an IKE_SA is currently ESTABLISHED. TR-1 requires IPsec" >&2
  echo "         to be inactive. Run: sudo ipsec down cs6530-site-to-site" >&2
  echo "         (or 'sudo systemctl stop strongswan-starter') before continuing." >&2
  exit 1
fi

# --- Build a recognizable, team-specific payload from both roll numbers ---
PAYLOAD_STR="${ROLL_NO_SITE_A}${ROLL_NO_SITE_B}"
PAYLOAD_STR="${PAYLOAD_STR:0:16}"   # ping -p accepts max 16 pad bytes
PAYLOAD_HEX="$(printf '%s' "$PAYLOAD_STR" | od -An -tx1 | tr -d ' \n')"

echo "[*] Team payload string : $PAYLOAD_STR"
echo "[*] Team payload hex    : $PAYLOAD_HEX"
echo "[*] Capturing on        : $WAN_IFACE (filter: icmp)"
echo "[*] Pinging             : $PEER_HOST_IP (inside $NETNS_NAME)"
echo

OUT_DIR="$REPO_ROOT/captures/tr1-baseline"
TS="$(date +%Y%m%d-%H%M%S)"
PCAP_FILE="$OUT_DIR/${TS}_${SITE_ARG}_tr1-baseline.pcap"
PING_LOG="$OUT_DIR/${TS}_${SITE_ARG}_tr1-ping.log"
mkdir -p "$OUT_DIR"

# --- Start capture ---
TCPDUMP_PID="$("$CAPTURE_SH" start "$WAN_IFACE" "icmp" "$PCAP_FILE")"
echo "[*] tcpdump started (PID $TCPDUMP_PID), capturing to $PCAP_FILE"
sleep 1

# --- Send team-specific ping from inside the namespace ---
echo "[*] Sending ping..."
ip netns exec "$NETNS_NAME" ping -c 4 -p "$PAYLOAD_HEX" "$PEER_HOST_IP" | tee "$PING_LOG"

# --- Stop capture ---
"$CAPTURE_SH" stop "$TCPDUMP_PID"
echo "[*] Capture stopped."

echo
echo "[*] Quick plaintext check (payload should be visible in hex/ASCII below):"
tcpdump -r "$PCAP_FILE" -X -n icmp 2>/dev/null | grep -A2 -i "$PAYLOAD_STR" || \
  echo "    (grep didn't match split hex dump lines — inspect $PCAP_FILE manually in Wireshark, this is expected and OK)"

echo
echo "== TR-1 complete =="
echo "Evidence saved:"
echo "   PCAP : $PCAP_FILE"
echo "   Log  : $PING_LOG"
echo "Open the PCAP in Wireshark and confirm: inner 10.x.0.10 addresses,"
echo "ICMP echo request/reply, and the team payload bytes visible in plaintext."