# CS6530 — Assignment 3: Site-to-Site IPsec/IKEv2

Site-to-site IKEv2/IPsec tunnel between two independently operated
gateway machines, built with strongSwan and Linux XFRM, covering all
Functional Requirements (FR-1–FR-8) and Testing Requirements
(TR-1–TR-8) from the assignment spec.

**Team**
| Name | Roll No. | Role |
|---|---|---|
| Sanchit Lodha | CE24B107 | Site A |
| Aayush Lal | CE24B033 | Site B |

**Report:** [`report/Assignment3_Report.pdf`](report/Assignment3_Report.pdf)
— full FR/TR results, diagnosis, and Wireshark evidence.

---

## Repo structure

```
.
├── common/                  # shared scripts, run on both machines
│   ├── netns-setup.sh        # FR-1: namespace + veth + routing
│   ├── teardown.sh           # tears down FR-1 state
│   ├── tunnel-up.sh          # FR-4: bring up IKE_SA/CHILD_SA
│   ├── status_snapshot.sh    # FR-6 evidence: statusall + xfrm state/policy
│   ├── capture.sh            # generic tcpdump start/stop wrapper
│   ├── ping-test.sh          # FR-5: bidirectional protected ping
│   └── restore-baseline.sh   # FR-8: generic reset to known-good config
├── config/
│   ├── site-a.env            # Site A's real values
│   ├── site-b.env            # Site B's real values
│   ├── ipsec.conf.template   # Appendix A/B template, placeholder-driven
│   └── ipsec.secrets.template
├── render-config.sh          # FR-2/FR-3: builds PSK + ipsec.conf from .env
├── tests/
│   ├── tr1-baseline.sh       # plaintext baseline
│   ├── tr2-protected.sh      # protected session + SPI correlation
│   ├── tr3-ikev2-capture.sh  # fresh handshake capture
│   ├── tr4-ike-mismatch.sh   # IKE proposal mismatch (break/restore)
│   ├── tr5-psk-mismatch.sh   # PSK mismatch (break/restore)
│   ├── tr6-esp-mismatch.sh   # ESP proposal mismatch (break/restore)
│   ├── tr7-selector-mismatch.sh  # traffic-selector mismatch (break/restore)
│   └── tr8-boundary.sh       # protected-side vs WAN-side capture
├── captures/                 # pcaps + snapshots produced by the tests above
├── evidence/                 # supplementary screenshots, if any
└── report/
    ├── Assignment3_Report.tex / .pdf
    ├── testing-procedure.md  # step-by-step run order for all tests
    └── figures/               # Wireshark screenshots embedded in the report
```

## Prerequisites (both machines)

```bash
sudo apt update
sudo apt install -y strongswan iproute2 iptables tcpdump wireshark
```

Each site needs its own Linux machine (or VM with **bridged**
networking) reachable from the other over a common LAN/hotspot.

## Quick start

1. Fill in `config/site-a.env` and `config/site-b.env` with each
   site's real WAN IP, interface name, and both team members' roll
   numbers (same values, same order, on both files).
2. On each machine:
   ```bash
   chmod +x common/*.sh tests/*.sh render-config.sh
   sudo ./common/netns-setup.sh site-a   # or site-b
   sudo ./render-config.sh site-a        # or site-b
   sudo ./common/tunnel-up.sh
   ```
3. Follow [`report/testing-procedure.md`](report/testing-procedure.md)
   for the full FR-1→FR-8, TR-1→TR-8 run order, including which
   commands run on which machine and when to coordinate a break/restore
   test with the other side.

All evidence (pcaps, `statusall`/`xfrm` snapshots) lands under
`captures/`, timestamped and labeled by test.

## Known issues

See Section 6 ("Known Issues / Debugging Log") of the report for a
full write-up of the real infrastructure problems hit and resolved
during this project: orphaned `charon` processes from mixing raw
`ipsec start/stop` with `systemctl`, a stale peer WAN IP after
switching networks, an unrendered config on Site B, and a background
`tcpdump` process that occasionally outlived its intended capture
window. None of these affected the validity of the final evidence.

## AI-use disclosure

Development of the automation scripts and this repository's structure
was assisted by Claude (Anthropic); see the report's AI-use disclosure
section for details. All configuration, command execution, and
evidence collection were performed by the team on their own machines.