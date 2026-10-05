#!/usr/bin/env bash
#
# capture.sh — generic tcpdump wrapper. Starts a background capture on
# the given interface/filter, returns its PID, and a matching stop
# function via a sentinel file. Reused by tr1-baseline.sh and later TRs.
#
# Usage:
#   ./capture.sh start <iface> <bpf-filter> <output.pcap>   -> prints PID
#   ./capture.sh stop  <PID>

set -euo pipefail

ACTION="${1:-}"

case "$ACTION" in
  start)
    IFACE="$2"; FILTER="$3"; OUT_PCAP="$4"
    mkdir -p "$(dirname "$OUT_PCAP")"
    # -U: packet-buffered output so the file is readable even before stop
    nohup tcpdump -l -n -U -i "$IFACE" -s 0 -w "$OUT_PCAP" $FILTER \
      > "${OUT_PCAP}.log" 2>&1 &
    TCPDUMP_PID=$!
    echo "$TCPDUMP_PID"
    ;;
  stop)
    PID="$2"
    sleep 1   # let a couple more packets land
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 start <iface> <bpf-filter> <output.pcap>" >&2
    echo "       $0 stop <PID>" >&2
    exit 1
    ;;
esac