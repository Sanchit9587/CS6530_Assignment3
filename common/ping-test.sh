#!/usr/bin/env bash
#
# ping-test.sh — FR-5 helper: quick protected-traffic ping with no
# capture, for confirming bidirectional connectivity through the
# tunnel. Run on each side in turn to demonstrate both directions.
#
# Usage: sudo ./ping-test.sh <site-a|site-b>

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 1 || ( "$1" != "site-a" && "$1" != "site-b" ) ]] && {
  echo "Usage: sudo $0 <site-a|site-b>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/config/${1}.env"

if ! ipsec statusall 2>/dev/null | grep -q "INSTALLED, TUNNEL"; then
  echo "ERROR: no INSTALLED CHILD_SA — bring the tunnel up first." >&2
  exit 1
fi

echo "[*] Pinging $PEER_HOST_IP from inside $NETNS_NAME (tunnel should carry this)..."
ip netns exec "$NETNS_NAME" ping -c 4 "$PEER_HOST_IP"
echo
echo "== If this succeeded, this direction's protected connectivity is confirmed. =="
echo "Run the equivalent on the peer machine for the other direction (FR-5 requires both)."