# Network Test Matrix (Phase 4)

Run these before each release. Use two devices, open `https://call.sottocall.com/` on one (or the app), and call its link from the other. During the call a small **Relayed** chip at the top means the call goes through the TURN server, and no chip means a direct connection; *Settings → Help → Diagnostic report* shows the route (`Call route: direct | relayed`).

| # | Device A network | Device B network | Hide my IP | Expected route | Result |
|---|---|---|---|---|---|
| 1 | Same Wi-Fi | Same Wi-Fi | off | Direct | |
| 2 | Same Wi-Fi | Same Wi-Fi | on (A) | Relayed | |
| 3 | Home Wi-Fi | Mobile data (4G/5G) | off | Direct or relayed | |
| 4 | Mobile data | Mobile data, different carrier | off | Usually relayed (carrier-grade NAT) | |
| 5 | Mobile data | Home Wi-Fi | on (B) | Relayed | |
| 6 | Office / hotel / guest Wi-Fi (UDP blocked) | Home Wi-Fi | off | Relayed (TURN over TCP/TLS) | |
| 7 | Windows app | Browser (Chrome/Edge) | off | Direct or relayed | |
| 8 | Android app | Browser (Safari on iPhone) | off | Direct or relayed | |
| 9 | Any | Any | on (both) | Relayed | |

For every row: the call connects within ~5 seconds, both sides see video and hear audio, and the safety numbers match.

## Forcing the hard cases

- **"Hide my IP address"** forces relay-only on that device, which is the quickest way to prove TURN works.
- **Block UDP** (simulates strict firewalls) on a laptop: `sudo iptables -A OUTPUT -p udp --dport 3478 -j DROP; sudo iptables -A OUTPUT -p udp --dport 49152:65535 -j DROP` (undo with `-D` instead of `-A`). The call must still connect, relayed over TCP/TLS.
- **Two mobile networks** are the most common real-world case that needs TURN.

## What the automated tests cover

The end-to-end test (`e2e/call.mjs`, run in CI) makes a normal call and checks it is **direct**, then turns on *Hide my IP address* and checks the next call connects **relayed** through a real coturn. Running it with a wrong TURN secret makes it fail, so it genuinely depends on TURN.
