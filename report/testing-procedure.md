# CS6530 Assignment 3 — Testing Procedure (FR1–FR4, TR1–TR4)

Run commands in the exact order below. "A:" = run on Student A's machine,
"B:" = run on Student B's machine (inside his Linux VM). Steps with no
prefix are done by whoever is coordinating that step; both should watch.

Before anything: confirm `.env` files are filled in correctly on both
sides (no `XXX`/`YYY` placeholders left), and do one last reachability
check:

```
A: ping <Student B's VM bridged IP>
B: ping 10.229.244.178
```

Both must succeed before proceeding.

---

## FR1 — Two-machine site topology (plain routing, no IPsec)

```
A: sudo ./common/netns-setup.sh site-a
B: sudo ./common/netns-setup.sh site-b
```

**Verify (either side):**
```
A: sudo ip netns exec hostA ping -c 4 10.2.0.10
```
Expected: 4 replies, 0% packet loss. This is plain IP reachability —
no encryption yet. Screenshot this for **E1-A/E1-B**.

If it fails: re-check both `.env` WAN IPs are correct and the earlier
ping test passed; re-run `netns-setup.sh` on the side that looks wrong.

---

## TR-1 — Baseline plaintext test

Run on **either** side (A shown here). IPsec must NOT be running yet —
the script checks this and refuses to continue otherwise.

```
A: sudo ./tests/tr1-baseline.sh site-a
```

**What it does:** builds a team-specific payload from both roll
numbers, captures ICMP on your WAN interface, pings the peer's
namespace IP, stops the capture.

**Verify:** open the printed `.pcap` path in Wireshark, filter `icmp`,
confirm the team payload bytes are visible in plaintext in the packet
bytes pane. This is **E1-C**.

---

## FR2 — Team-specific IKE authentication (PSK)

```
A: sudo ./render-config.sh site-a
B: sudo ./render-config.sh site-b
```

**Verify (both sides):**
```
cat /etc/ipsec.secrets
```
Confirm the PSK string is **identical** on both machines (same roll
numbers, same order, same suffix). If they don't match, authentication
will fail later — fix `.env` and re-run before continuing.

---

## FR3 — Site-to-site traffic selectors

Already rendered by `render-config.sh` above (it writes `ipsec.conf`
too). Just double-check it on both sides:

```
cat /etc/ipsec.conf
```
Confirm `leftsubnet`/`rightsubnet` show `10.1.0.0/24` and `10.2.0.0/24`
(mirrored correctly between the two machines), and `left`/`right` show
the correct WAN IPs.

---

## FR4 — IKE_SA and CHILD_SA establishment

```
A: sudo ./common/tunnel-up.sh
B: sudo ./common/tunnel-up.sh
```

Run on **both** machines (order doesn't matter much, but it's cleanest
if both run it within a minute of each other).

**Verify:** each script prints `ESTABLISHED` and `INSTALLED, TUNNEL`
plus the two ESP SPIs. If one side fails, check the other side ran
`render-config.sh` correctly and the PSK/proposals match.

Save formal evidence:
```
A: sudo ./common/status_snapshot.sh fr4-established-site-a
B: sudo ./common/status_snapshot.sh fr4-established-site-b
```
This is your **E2-A/E2-B** baseline evidence (statusall + xfrm
state + xfrm policy), reused again in TR-2.

---

## TR-2 — Normal protected session

Run on **either** side (A shown). Tunnel must already be
`ESTABLISHED`/`INSTALLED` from FR4 above — the script checks this.

```
A: sudo ./tests/tr2-protected.sh site-a
```

**What it does:** repeats the exact same ping/payload as TR-1, but
captures only `esp` this time, snapshots status/xfrm again, confirms
the payload is **not** visible in plaintext, and prints the ESP SPI
seen on the wire.

**Verify:** compare the printed SPI against the SPI line in the
`ip xfrm state` section of the snapshot file — they should match. Open
the `.pcap` in Wireshark, confirm no ICMP/payload bytes are readable
(only encrypted ESP). This is **E2-C**.

---

## TR-3 — IKEv2 exchange capture

Run on **either** side (A shown).

```
A: sudo ./tests/tr3-ikev2-capture.sh site-a
```

**What it does:** forces the tunnel down, captures `udp/500`,
`udp/4500` and `esp`, brings the tunnel back up (fresh handshake), then
stops the capture.

**Verify:** open the `.pcap` in Wireshark, filter `isakmp`. Identify
and screenshot:
- IKE_SA_INIT request and response
- IKE_AUTH request and response
- subsequent `esp` packets

This is **E3** (D3 deliverable: the team PCAP).

---

## TR-4 — IKE proposal mismatch

**Decide who breaks their config** (suggestion: Student B, matching
our earlier task split). The other side just takes a snapshot at the
same time.

```
B: sudo ./tests/tr4-ike-mismatch.sh site-b break
```

At the same time:
```
A: sudo ./common/status_snapshot.sh tr4-ike-mismatch-observed-site-a
```

**What `break` does:** writes a mismatched IKE proposal
(`aes128-sha256-modp2048!`) into Site B's `ipsec.conf` only, restarts
strongSwan, attempts `ipsec up` (expected to fail), captures the failed
`IKE_SA_INIT` negotiation, snapshots status/xfrm, confirms no
`ESTABLISHED` SA, and automatically tests plain ping reachability to
classify the effect as connectivity-only, protection-only, or both.

**Verify:** confirm the script reports IKE_SA did **not** establish,
and read its reachability verdict. Screenshot/save this — **E4-B**
(Site B) and **E4-A** (Site A, from the snapshot above) and **E4-C**
(the pcap).

**Restore (FR-8, required before moving on):**
```
B: sudo ./tests/tr4-ike-mismatch.sh site-b restore
```
Confirm it reports `ESTABLISHED` + `INSTALLED, TUNNEL` again before
considering TR-4 done.

---

## Evidence checklist after this run

| ID | File/location |
|----|----------------|
| E1-A/E1-B | terminal output of FR1 ping test |
| E1-C | `captures/tr1-baseline/*.pcap` |
| E2-A/E2-B | `captures/snapshots/*fr4-established*` |
| E2-C | `captures/tr2-protected/*.pcap` + snapshot |
| E3 | `captures/tr3-ikev2-handshake/*.pcap` |
| E4-A | `captures/snapshots/*tr4-ike-mismatch-observed-site-a*` |
| E4-B | `captures/snapshots/*tr4-ike-mismatch-break-site-b*` |
| E4-C | `captures/tr4-ike-mismatch/*.pcap` |

Copy relevant screenshots into `evidence/site-a/` and
`evidence/site-b/` as you go, per the repo structure.