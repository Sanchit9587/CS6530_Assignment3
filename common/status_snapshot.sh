#!/usr/bin/env bash
#
# status_snapshot.sh — captures ipsec statusall + ip xfrm state + ip xfrm
# policy into one timestamped evidence file. Used for FR4/FR6 evidence
# and reused for every TR (TR-2, TR-4, TR-5, TR-6, TR-7).
#
# Usage: sudo ./status_snapshot.sh <label>
#   label examples: fr4-established, tr4-ike-mismatch, tr5-psk-fail

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "ERROR: run with sudo." >&2; exit 1; }
[[ $# -ne 1 ]] && { echo "Usage: sudo $0 <label>" >&2; exit 1; }

LABEL="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/captures/snapshots"
mkdir -p "$OUT_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
HOSTNAME_SHORT="$(hostname -s)"
OUT_FILE="$OUT_DIR/${TS}_${HOSTNAME_SHORT}_${LABEL}.txt"

{
  echo "===== status_snapshot : $LABEL ====="
  echo "Host    : $(hostname)"
  echo "Time    : $(date)"
  echo
  echo "----- sudo ipsec statusall -----"
  ipsec statusall 2>&1 || echo "(ipsec statusall failed/empty)"
  echo
  echo "----- sudo ip xfrm state -----"
  ip xfrm state 2>&1 || echo "(ip xfrm state failed/empty)"
  echo
  echo "----- sudo ip xfrm policy -----"
  ip xfrm policy 2>&1 || echo "(ip xfrm policy failed/empty)"
} | tee "$OUT_FILE"

echo
echo "== Saved snapshot: $OUT_FILE =="