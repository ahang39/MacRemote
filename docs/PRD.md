# Product Requirements Document (PRD)

Status: **Draft 0.1 — 2026-11-13**
Owner: MacRemote project
Implementation status: **private Alpha: macOS TLS+PAM account login path, unrestricted keyboard/mouse and network binding built; real successful Windows mstsc login pending**

## 1. Problem and positioning

Cross-platform users can easily open an RDP client on Windows, yet macOS has no universally adopted, polished, open RDP server with a strong office-first experience. MacRemote aims to deliver **reliable standard-RDP access to a Mac with minimal setup and measurable weak-network performance**.

The publication goal is a useful, independently buildable project with public source, reproducible tests and transparent release gates.

## 2. Personas and jobs to be done

1. **Developer:** Windows workstation to personal Mac mini/Studio; spends hours in IDE, terminal, browsers; needs crisp glyphs, working modifiers/IME, accurate scroll and drag.
2. **Unattended Mac user:** connects to an already logged-in Mac session over a private network; expects safe startup, reconnect and recoverability.
3. **Mobile/Linux user:** uses an existing standards-compliant RDP app without installing a MacRemote-specific client.

## 3. Scope and requirements

Priority meaning: **P0** = prerequisite for first usable MVP; **P1** = needed for daily-use beta; **P2** = after beta. "M0" means documentation-only foundation.

| ID | Priority | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| R-01 | P0 | mstsc negotiates a standard RDP connection | Captured successful client handshake and desktop session |
| R-02 | P0 | Authenticate and authorize the intended logged-in macOS user | No anonymous desktop control; cross-user and invalid-login cases rejected |
| R-03 | P0 | Capture the existing physical display using supported macOS APIs | Correct display, dimensions, cursor and updates during typical workflows |
| R-04 | P0 | Physical-like keyboard semantics, mouse, modifiers, scroll, drag, and key release | End-to-end local-vs-remote parity matrix, including Chinese/English and reconnect |
| R-04a | P1 / M1 research | Applicable existing Karabiner mappings work automatically with no extra adapter or duplicated configuration | Global rules applied once on a verified HID path; device-specific behavior and OS permission needs documented |
| R-05 | P0 | Encryption, constrained listening and clean session teardown | No cleartext credentials; no orphaned input state after failures |
| R-06 | P0 | Work over ordinary IP networking and private TCP forwarding | LAN and HY2-tunneled TCP can both connect without a vendor relay |
| R-07 | P0 | At least basic transfer/encoding diagnostics | Actual bytes/sec, negotiated codec, sent FPS, connection state; unknowns shown as N/A |
| R-08 | P1 | Sharp text and adaptive low-bandwidth behavior | Reproducible screenshots and benchmark results under fixed link conditions |
| R-09 | P1 | Simple native menu bar and CLI UX | Install/authorize/connect/status/diagnose without editing multiple configs |
| R-10 | P0 (plain text), P1 (rich formats/audio) | Correct bidirectional clipboard sync and platform newline conversion | No duplicate blank lines, paste actions or sync feedback with mstsc and WeChat Input Method; see ADR-0004 |
| R-10a | P1 | Rich clipboard formats and audio | Format precedence and channel safety tests |
| R-11 | P1 | Disconnect/reconnect, wake and display-change robustness | Automated recovery matrix, no unbounded queues or memory leak |
| R-12 | P1 | Display changes follow client requests where safe | Correct layout and supported physical-mode transitions; restore after exit |
| R-13 | P2 | Optional virtual display and headless operation | Independent security/platform review; never relied on by MVP |
| R-14 | P2 | Standard RDP UDP multitransport | Measurable improvement with supported clients; TCP fallback verified |

### UX and configuration

- **Minimal surface** (proposed, not implemented): listener/binding, connection authorization, quality preset, display selection only where needed.
- Default to all-interface listening on TCP 3389, with optional --bind IP and a persistent custom menu port. Standard input and upstream client handling, no extra RDP account.
- Observability should be visible in the menu-bar UI and CLI, with **clearly labeled units and metric provenance**.
- No account system, subscriptions, telemetry upload, external gateway, or required cloud service.
- No external keyboard mapping adapter or duplicated Karabiner configuration. A native HID backend may need a separately approved macOS entitlement; ordinary keyboard usage must work without Karabiner.

## 4. Non-functional goals (targets, not results)

Measured at 1920×1080 on a fixed Apple Silicon test host:

| Test condition | Initial target |
| --- | --- |
| Static desktop, settled | <= 50 Kbps payload traffic (excluding an explicitly measured transport overhead) |
| Active editing/scrolling, 2–5 Mbps WAN | Usable controls, crisp stationary text, no persistent frame backlog |
| Capture to outbound-queue latency | p95 <= 50 ms on local test host |
| Long-running beta test | 72 hours without crash, deadlock, or unbounded memory/queue growth |
| WAN 80 ms RTT / 2 Mbps | Maintain interactive editing; dynamically sacrifice video smoothness before input responsiveness |

No claim of beating NuoRDS, macrdp or FreeRDP before side-by-side tests. See [TESTING.md](TESTING.md) for methodology and additional link profiles.

## 5. Security and operational constraints

- Secure, user-bound authorization; treat RDP auth and macOS desktop entitlement as separate concerns until proven linked.
- Respect Screen Recording/Input Monitoring/Accessibility permissions (TCC). No implicit privilege escalation.
- Only the **already logged-in user's session** in the first release; loginwindow, FileVault pre-boot and multi-user isolated sessions are not promised.
- Use public macOS APIs for core features. Private APIs may appear only in isolated, disabled-by-default experiments.
- Avoid writing credentials or display contents to logs; local diagnostic export is opt-in and sanitized.

## 6. Explicit non-goals for MVP

New desktop client; cloud signaling service; custom remote protocol; obligatory HY2 integration; web gateway; public-facing default RDP listener; multi-tenant terminal-server sessions; proprietary NuoRDS protocol/code replication.

## 7. Phase gates

- **M0:** source-controlled product docs, ADRs, testing and engineering rules; no app or runtime.
- **M1:** FreeRDP selected as the product foundation. Native HID/Karabiner and CLIPRDR/IME validation continue in ADR-0003 and ADR-0004.
- **M2:** native C server + SwiftUI menu bar use macOS account password via TLS+PAM, all-interface listener and native input; standalone bundle and basic mstsc Classic connection have been verified, full regression remains.
- **M3:** validate P1 performance/reliability goals with comparable baselines.
- **M4:** complete third-party license audit, security review, Developer ID signing/notarization and a reviewed binary release.

## 8. Open questions, deliberately deferred

RDP library, credential/authorization model, native HID entitlements and Karabiner compatibility, support for session wake/login screen, virtual display strategy, actual supported codec modes, installer identity, minimum bandwidth promise.

Only measured research may resolve these; do not backfill guesses as decisions.
