# Engineering Rules

Status: **effective immediately**

## Principles

1. **Small steps, measured improvements.** Prefer the smallest correct change. Do not create infrastructure before it is needed.
2. **Use mature dependencies.** Standard library → platform API → existing popular OSS → new implementation. Avoid rewriting RDP and copying NuoRDS internals.
3. **Document facts separately from plans.** Never mark proposed features, benchmarks or upstream capabilities as already implemented.
4. **Safe local development.** Do not alter macOS system security/network settings, existing remote access software or secrets to make tests pass.
5. **Keep the configuration surface small.** Every new knob needs a user scenario, sensible default, bounded value, and test; observability is not a reason to expose dozens of tuning flags.
6. **Input and security first.** Auth/session controls, key-release correctness and bounded queues are mandatory design reviews.
7. **Native input over mapping hacks.** Do not create an additional key adapter or reimplement Karabiner configuration. Evaluate HID and keep a truthful Quartz fallback.
8. **Clipboard correctness over hacks.** Normalize plain-text CRLF/LF at protocol boundary, never synthesize a paste on clipboard notification; verify duplicate actions separately from newline inflation.

## Repository conventions

- Default branch: `main`; development is local-only until explicitly approved for publication.
- English is authoritative for the PRD, architecture, testing and ADRs; maintain a concise Chinese overview.
- ADR for major irreversible choices (protocol stack, process model, privileged integration, virtual display). Keep an Accepted ADR accurate if decisions change.
- No third-party implementation copied before license review. License selection remains open and is required before public release.
- Product name `MacRemote`, native CLI name `macremote`. Bundle ID and any future process split remain undecided.

## Minimal change workflow

1. Read relevant PRD / ADR and current code.
2. State the single testable behavior changed; identify risks.
3. Write or adjust focused tests with the implementation.
4. Run the narrowest relevant checks, then broader checks when warranted.
5. Review the diff, dependencies, secrets and docs before committing.
6. Record exact measured outcomes and unresolved limitations.

## Testing conventions

- Report actual commands/versions and pass/fail state. Distinguish tests that were not run.
- Use deterministic, local test inputs where possible.
- Set up separate non-conflicting test ports; no silent overwrite of NuoRDS or existing network configurations.
- Expose factual diagnostics (codec, network rate, stage FPS/latencies), mark unsupported metrics as unavailable.
- Security findings and crashes take priority over small performance wins.

## Current stage / change budget

**Private Alpha:** Use standard Mac username/password through FreeRDP TLS+PAM (ADR-0007). Do not reintroduce separate pairing, forced NLA, localhost-only, read-only, console-owner or one-client caps. All-interface TCP 3389 default, with persistent custom port and CLI overrides. Do not log actual passwords. Self-contained local signing is complete; full Windows mstsc regression, third-party license compliance and Developer ID notarization remain release gates.
