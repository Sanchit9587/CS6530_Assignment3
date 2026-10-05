# CS6530 Assignment 3 — Full Testing Procedure (FR-1→FR-8, TR-1→TR-8)

Run in this exact order — it follows dependency order, not numeric
order (e.g. TR-1 must run *before* the tunnel comes up). `A:` = run on
Student A's machine, `B:` = run on Student B's machine. Steps with no
prefix are done by whoever is coordinating; both should watch.

Always `chmod +x common/*.sh tests/*.sh render-config.sh` once per
machine before first use. Use `sudo systemctl restart
strongswan-starter` to restart strongSwan — never raw `ipsec
start`/`stop`, which can orphan the `charon` process (see report
Section 6).

---

## Pre-flight

```
A: ping <Site B's WAN IP>
B: ping <Site A's WAN IP>
```
Both must succeed before continuing. If blocked, try a mobile hotspot
or direct ethernet link instead of campus Wi-Fi.

Fill in `config/site-a.env` and `config/site-b.env`: WAN IP, WAN
interface name, and both members' roll numbers (identical values,
identical order, on both files).

---

## FR-1 — Two-machine site topology

```
A: sudo ./common/netns-setup.sh site-a
B: sudo ./common/netns-setup.sh site-b
```

**Verify:**
```
A: sudo ip netns exec hostA ping -c 4 10.2.0.10
B: sudo ip netns exec hostB ping -c 4 10.1.0.10
```
Expect 4/4 replies, 0% loss, both directions. This is plain routing —
no IPsec yet. Evidence: **E1-A**, **E1-B**.

> Namespaces don't survive a reboot — re-run `netns-setup.sh` after
> any restart of either machine.

---

## TR-1 — Baseline plaintext test

Run on either side (A shown) while IPsec is **not** active yet.

```
A: sudo ./tests/tr1-baseline.sh site-a
```
Builds a team payload from both roll numbers, captures ICMP on the WAN
interface, pings the peer namespace.

**Verify:** open the printed `.pcap` in Wireshark (or
`tcpdump -r <file> -X -n icmp`), confirm the payload bytes are visible
in plaintext. Evidence: **E1-C**.

---

## FR-2 — Team-specific IKE authentication (PSK)

```
A: sudo ./render-config.sh site-a
B: sudo ./render-config.sh site-b
```

**Verify (both sides):**
```
sudo cat /etc/ipsec.secrets
```
PSK string must be **character-for-character identical** on both
machines.

---

## FR-3 — Site-to-site traffic selectors

Already rendered by `render-config.sh` above. Confirm:
```
sudo cat /etc/ipsec.conf
```
`leftsubnet`/`rightsubnet` must show `10.1.0.0/24` and `10.2.0.0/24`,
mirrored correctly between the two machines.

---

## FR-4 — IKE_SA and CHILD_SA establishment

```
A: sudo systemctl restart strongswan-starter
B: sudo systemctl restart strongswan-starter
A: sudo ./common/tunnel-up.sh
B: sudo ./common/tunnel-up.sh
```

**Verify (both sides):**
```
sudo ipsec statusall | cat
```
Look for `ESTABLISHED` and `INSTALLED, TUNNEL` with two ESP SPIs.

Save evidence:
```
A: sudo ./common/status_snapshot.sh fr4-established-site-a | cat
B: sudo ./common/status_snapshot.sh fr4-established-site-b | cat
```
Evidence: **E2-A**, **E2-B**.

---

## FR-5 — Protected bidirectional communication

```
A: sudo ./common/ping-test.sh site-a
B: sudo ./common/ping-test.sh site-b
```
Both directions must show 4/4 replies, 0% loss, now flowing through
the CHILD_SA instead of plain routing.

---

## FR-6 — Observable security state

```
A: sudo ip xfrm policy | cat
A: sudo ip xfrm state | cat
B: sudo ip xfrm policy | cat
B: sudo ip xfrm state | cat
```
Confirm the SPD (policy) and SAD (state) on each side mirror the
other's subnets/SPIs, and connect the chain: `ipsec statusall` →
`ip xfrm policy` → `ip xfrm state` → SPI → wire packet.

---

## TR-2 — Normal protected session

Tunnel must already be up (FR-4).

```
A: sudo ./tests/tr2-protected.sh site-a
```
Repeats TR-1's exact payload, captures `esp` only, auto-checks the
payload is **not** in plaintext, prints the SPI for correlation with
`ip xfrm state`. Evidence: **E2-C**.

---

## FR-7 — Packet evidence / TR-3 — IKEv2 exchange capture

```
A: sudo ./tests/tr3-ikev2-capture.sh site-a
```
Forces the tunnel down, captures `udp/500`, `udp/4500`, `esp`, brings
it back up (fresh handshake), sends test pings.

**In Wireshark:** filter `isakmp` → identify IKE_SA_INIT req/resp,
IKE_AUTH req/resp. Filter `esp` → confirm subsequent protected
traffic. Screenshot both. Evidence: **E3** (also **D3**, also FR-7).

---

## TR-4 — IKE proposal mismatch

Decide who breaks (suggestion: Student B).

```
B: sudo ./tests/tr4-ike-mismatch.sh site-b break
A: sudo ./common/status_snapshot.sh tr4-ike-mismatch-observed-site-a | cat
```
Expect `NO_PROPOSAL_CHOSEN` on IKE_SA_INIT, no CHILD_SA. Evidence:
**E4-A**, **E4-B**, **E4-C**.

**Restore (FR-8):**
```
B: sudo ./tests/tr4-ike-mismatch.sh site-b restore
```
Confirm `ESTABLISHED`/`INSTALLED, TUNNEL` on both sides before
continuing.

---

## TR-5 — PSK authentication failure

```
B: sudo ./tests/tr5-psk-mismatch.sh site-b break
A: sudo ./common/status_snapshot.sh tr5-psk-mismatch-observed-site-a | cat
```
Expect `AUTHENTICATION_FAILED` on IKE_AUTH, no CHILD_SA. Evidence:
**E5-A**, **E5-B**, **E5-C**.

**Restore (FR-8):**
```
B: sudo ./tests/tr5-psk-mismatch.sh site-b restore
```

---

## TR-6 — ESP proposal mismatch

```
B: sudo ./tests/tr6-esp-mismatch.sh site-b break
A: sudo ./common/status_snapshot.sh tr6-esp-mismatch-observed-site-a | cat
```
Expect IKE_SA `ESTABLISHED` but **no** `INSTALLED, TUNNEL` line
(`NO_PROPOSAL_CHOSEN` at CREATE_CHILD_SA stage). Evidence: **E6-A**,
**E6-B**, **E6-C**.

**Restore (FR-8):**
```
B: sudo ./tests/tr6-esp-mismatch.sh site-b restore
```

---

## TR-7 — Traffic-selector mismatch

```
B: sudo ./tests/tr7-selector-mismatch.sh site-b break
A: sudo ./common/status_snapshot.sh tr7-selector-mismatch-observed-site-a | cat
B: tcpdump -r captures/tr7-selector-mismatch/*.pcap -n
```
Check: does `ip xfrm policy` show the wrong selector with no match for
real traffic? Does the pcap show plaintext ICMP (protection failure)
or no packets at all (connectivity failure)? Classify accordingly.
Evidence: **E7-A**, **E7-B**, **E7-C**.

**Restore (FR-8):**
```
B: sudo ./tests/tr7-selector-mismatch.sh site-b restore
```

---

## TR-8 — Security-boundary observation

Tunnel must be fully restored and up.

```
A: sudo ./tests/tr8-boundary.sh site-a
```
Captures the same ping simultaneously on the protected-side interface
(`vethA-host`, expect plaintext) and the WAN interface (`wlp1s0`,
expect ESP only). Evidence: **E8-A**, **E8-C** (run on B too for
**E8-B** if desired).

---

## FR-8 — Restoration after failure (summary)

Satisfied cumulatively by the four restore steps above (TR-4 through
TR-7). If anything is left in a broken state at the end, run the
universal reset:
```
sudo ./common/restore-baseline.sh <site-a|site-b>
```

---

## Evidence checklist

| ID | Location |
|----|----------|
| E1-A/E1-B | FR-1 ping terminal output |
| E1-C | `captures/tr1-baseline/*.pcap` |
| E2-A/E2-B | `captures/snapshots/*fr4-established*` |
| E2-C | `captures/tr2-protected/*.pcap` |
| E3 | `captures/tr3-ikev2-handshake/*.pcap` + Wireshark screenshots |
| E4-A/E4-B | `captures/snapshots/*tr4-ike-mismatch*` |
| E4-C | `captures/tr4-ike-mismatch/*.pcap` |
| E5-A/E5-B | `captures/snapshots/*tr5-psk-mismatch*` |
| E5-C | `captures/tr5-psk-mismatch/*.pcap` |
| E6-A/E6-B | `captures/snapshots/*tr6-esp-mismatch*` |
| E6-C | `captures/tr6-esp-mismatch/*.pcap` |
| E7-A/E7-B | `captures/snapshots/*tr7-selector-mismatch*` |
| E7-C | `captures/tr7-selector-mismatch/*.pcap` |
| E8-A/E8-B/E8-C | `captures/tr8-boundary/*.pcap` |