#!/usr/bin/env bash
#
# netns-setup.sh — FR1: Two-machine site topology (plain routed connectivity,
# no IPsec yet). Run this on EACH machine with its own site argument.
#
# Usage:
#   sudo ./netns-setup.sh site-a      # on Student A's machine
#   sudo ./netns-setup.sh site-b      # on Student B's machine
#
# What it does:
#   1. Loads config/<site>.env
#   2. Creates a network namespace representing the protected host
#   3. Creates a veth pair linking the namespace to the host (gateway)
#   4. Assigns protected-subnet IPs on both ends of the veth
#   5. Enables IPv4 forwarding on the gateway (this machine)
#   6. Adds routes so the local protected host can reach the peer's
#      protected subnet via this gateway, and the gateway knows to
#      route peer-subnet traffic out its WAN interface
#
# Idempotent: safe to re-run after teardown.sh, or re-run directly
# (it cleans up any stale namespace/veth from a previous run first).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this with sudo." >&2
  exit 1
fi

if [[ $# -ne 1 || ( "$1" != "site-a" && "$1" != "site-b" ) ]]; then
  echo "Usage: sudo $0 <site-a|site-b>" >&2
  exit 1
fi

SITE_ARG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/config/${SITE_ARG}.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# --- sanity: refuse to run with unfilled placeholders ---
for var in MY_WAN_IP PEER_WAN_IP ROLL_NO_SITE_A ROLL_NO_SITE_B; do
  val="${!var}"
  if [[ "$val" == *XXX* || "$val" == *YYY* ]]; then
    echo "ERROR: $var in $ENV_FILE still looks like a placeholder ('$val')." >&2
    echo "       Fill in your real value before running." >&2
    exit 1
  fi
done

echo "== netns-setup.sh : $SITE_ARG =="
echo "   namespace     : $NETNS_NAME"
echo "   gateway (host): $MY_GATEWAY_IP"
echo "   netns host IP : $MY_HOST_IP"
echo "   my WAN IP     : $MY_WAN_IP"
echo "   peer WAN IP   : $PEER_WAN_IP"
echo "   my subnet     : $MY_SUBNET"
echo "   peer subnet   : $PEER_SUBNET"
echo

# ------------------------------------------------------------------
# 1. Clean up any stale state from a previous run
# ------------------------------------------------------------------
if ip netns list | grep -qw "$NETNS_NAME"; then
  echo "[*] Removing stale namespace $NETNS_NAME"
  ip netns del "$NETNS_NAME"
fi
if ip link show "$VETH_HOST" &>/dev/null; then
  echo "[*] Removing stale veth $VETH_HOST"
  ip link del "$VETH_HOST" 2>/dev/null || true
fi

# ------------------------------------------------------------------
# 2. Create namespace + veth pair
# ------------------------------------------------------------------
echo "[*] Creating namespace $NETNS_NAME"
ip netns add "$NETNS_NAME"

echo "[*] Creating veth pair $VETH_HOST <-> $VETH_NS"
ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
ip link set "$VETH_NS" netns "$NETNS_NAME"

# ------------------------------------------------------------------
# 3. Assign IPs
# ------------------------------------------------------------------
echo "[*] Assigning $MY_GATEWAY_IP to $VETH_HOST (gateway side)"
ip addr add "$MY_GATEWAY_IP" dev "$VETH_HOST"
ip link set "$VETH_HOST" up

echo "[*] Assigning $MY_HOST_IP to $VETH_NS inside $NETNS_NAME (protected host side)"
ip netns exec "$NETNS_NAME" ip addr add "$MY_HOST_IP" dev "$VETH_NS"
ip netns exec "$NETNS_NAME" ip link set "$VETH_NS" up
ip netns exec "$NETNS_NAME" ip link set lo up

# ------------------------------------------------------------------
# 4. Default route inside the namespace -> gateway
# ------------------------------------------------------------------
GATEWAY_IP_ONLY="${MY_GATEWAY_IP%/*}"
echo "[*] Setting default route inside $NETNS_NAME via $GATEWAY_IP_ONLY"
ip netns exec "$NETNS_NAME" ip route add default via "$GATEWAY_IP_ONLY"

# ------------------------------------------------------------------
# 5. Enable IPv4 forwarding on this gateway machine
# ------------------------------------------------------------------
echo "[*] Enabling IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# ------------------------------------------------------------------
# 6. Route to the peer's protected subnet via the peer's WAN IP
#    (this is PLAIN routing for FR1 — no IPsec applied yet)
# ------------------------------------------------------------------
echo "[*] Adding route: $PEER_SUBNET via $PEER_WAN_IP"
ip route replace "$PEER_SUBNET" via "$PEER_WAN_IP"

# ------------------------------------------------------------------
# 7. NAT/forwarding rule so namespace traffic can exit via WAN iface
#    (needed because the namespace's source IP, 10.x.0.10, is not
#    directly routable on the peer's WAN without this gateway
#    forwarding it as-is — we rely on plain routing here per FR1,
#    not NAT, since the peer already has a route back to our subnet)
# ------------------------------------------------------------------
echo "[*] Ensuring FORWARD chain allows traffic (lab default-allow)"
iptables -P FORWARD ACCEPT 2>/dev/null || true

echo
echo "== FR1 setup complete for $SITE_ARG =="
echo "Next: confirm with peer that BOTH sides have run this script, then test:"
echo "   sudo ip netns exec $NETNS_NAME ping -c 4 \$(peer host IP)"
echo "Example: sudo ip netns exec $NETNS_NAME ping -c 4 ${PEER_SUBNET%.0/24}.10"