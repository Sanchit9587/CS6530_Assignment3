#!/usr/bin/env bash
#
# restore-baseline.sh — FR-8: restore the known-good configuration
# after ANY deliberate failure test (TR-4/5/6/7), re-render from the
# untouched .env file, bring the tunnel back up, verify.
#
# Usage: sudo ./restore-baseline.sh <site-a|site-b>

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 1 || ( "$1" != "site-a" && "$1" != "site-b" ) ]] && {
  echo "Usage: sudo $0 <site-a|site-b>" >&2; exit 1; }

SITE_ARG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONN_NAME="cs6530-site-to-site"

echo "[*] Re-rendering ipsec.conf / ipsec.secrets from config/${SITE_ARG}.env (known-good values)"
"$REPO_ROOT/render-config.sh" "$SITE_ARG"

echo "[*] Restarting strongSwan via systemctl (avoids orphaned-process issues)"
systemctl restart strongswan-starter
sleep 2

echo "[*] Bringing connection up"
if ipsec up "$CONN_NAME"; then
  sleep 2
  if ipsec statusall | grep -q "ESTABLISHED" && ipsec statusall | grep -q "INSTALLED, TUNNEL"; then
    echo "== RESTORED: IKE_SA ESTABLISHED + CHILD_SA INSTALLED =="
    "$REPO_ROOT/common/status_snapshot.sh" "restored-${SITE_ARG}"
    exit 0
  fi
fi

echo "ERROR: restore did not fully succeed — check peer side is also restored." >&2
exit 1