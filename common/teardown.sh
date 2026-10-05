#!/usr/bin/env bash
# teardown.sh — remove the namespace/veth/route created by netns-setup.sh
# Usage: sudo ./teardown.sh <site-a|site-b>

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 1 ]] && { echo "Usage: sudo $0 <site-a|site-b>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/config/${1}.env"
# shellcheck disable=SC1090
source "$ENV_FILE"

echo "[*] Deleting route to $PEER_SUBNET"
ip route del "$PEER_SUBNET" via "$PEER_WAN_IP" 2>/dev/null || true

echo "[*] Deleting namespace $NETNS_NAME (also removes $VETH_NS)"
ip netns del "$NETNS_NAME" 2>/dev/null || true

echo "[*] Deleting veth $VETH_HOST (if still present)"
ip link del "$VETH_HOST" 2>/dev/null || true

echo "== Teardown complete for $1 =="