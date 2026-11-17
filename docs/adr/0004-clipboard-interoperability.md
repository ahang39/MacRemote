# ADR-0004: Clipboard fidelity and input-method interoperability

- Status: **Accepted — implementation under real-client verification**
- Date: 2026-11-13
- Priority: P0 plain-text clipboard; other formats deferred

## Problem statement

In an existing Windows mstsc -> Mac setup, interaction between the RDP clipboard and 微信输入法 (WeChat Input Method) has reportedly caused **duplicate blank lines and/or repeated paste**. The user suspects line-ending differences. **This is an observation, not yet a verified root cause**.

Distinguish these separate failure classes:

1. **Content corruption:** one paste adds extra line breaks (for example mishandled Windows CRLF).
2. **Action duplication:** one paste shortcut causes two insertions (keyboard event handling, IME actions, or both).
3. **Synchronization feedback:** a mirrored clipboard update triggers reciprocal updates or notifications.
4. **Format mismatch:** plain text, rich text and IME-owned clipboard representations disagree.

## Design: ClipboardBridge at the protocol/platform boundary

Use the selected RDP library's standard **CLIPRDR** implementation, isolated behind a platform bridge. Standard MS-RDPECLIP format announcements, delayed rendering and requests should remain intact.

**Plain-text newline rules:**

- Decode Windows CF_UNICODETEXT as UTF-16LE with valid terminator handling. Convert CRLF into macOS-friendly LF for the plain-text representation.
- Export macOS plain text to Windows CF_UNICODETEXT using CRLF, UTF-16LE and correct termination.
- Handle isolated CR explicitly; no blind global string replacements that can create CRCRLF.
- Preserve user-intended empty lines and leading/trailing newline count; conversion must be idempotent across repeated round trips.
- Do not apply plain-text newline transformations to HTML, RTF, files, images or opaque clipboard formats.

**Event and synchronization rules:**

- A clipboard change **does not equal a paste**. Never synthesize Cmd+V or Ctrl+V in response to a format announcement or clipboard update.
- Distinguish RDP clipboard event, pasteboard ownership/change generation, format data request, and an actual user paste keyboard event.
- Track per-session origin/generation to prevent self-echo; avoid deduplicating legitimate separate copy events solely because their content is equal.
- Handle reconnection and rapid updates without stale ownership or unbounded queues.
- Work with macOS native IMEs and third-party clipboard tools without modifying their settings or installing additional adapters.

## Acceptance tests

Use synthetic non-sensitive text and record exact line-ending code points at source/transfer/destination in a private test harness.

| Input / condition | Expected behavior |
| --- | --- |
| `one\\r\\ntwo` | One newline, one insertion |
| `one\\ntwo` / `one\\rtwo` | Defined and stable import behavior |
| `one\\r\\n\\r\\ntwo` | Exactly one intentional blank line |
| Leading/trailing line breaks, mixed CR/LF | No added or dropped blank line |
| Chinese, emoji, tabs, combining marks | Text preserved |
| Repeated format announcements without paste | Clipboard sync only; no inserted text |
| Single paste shortcut | Exactly one insertion |
| Same text copied twice intentionally | Second real copy is not silently suppressed |
| Clipboard manager running | No sync echo loop or duplicated notifications |
| WeChat Input Method (clipboard/history on/off) vs macOS IME | No extra lines or duplicate paste |
| Mac -> Windows and Windows -> Mac | Equivalent text after platform normalization |
| Text/HTML/RTF advertised together | Chosen format deterministic; no simultaneous duplicate insertion |
| Disable CLIPRDR or reconnect | Clean state transition and recovery |

Test baseline apps: Windows Notepad / VS Code; macOS TextEdit plain text / VS Code; 微信输入法 with consented test-mode settings. **Do not modify the user's current IME or clipboard settings in M0.**

## Telemetry and privacy

For optional local diagnostics record only format identifier, size, change generation, event/request count, transfer duration and measured suppression count. **Never log clipboard contents, screenshots, filenames, raw Unicode strings, or persistent content hashes.** Mark unmeasurable values N/A.

## Exit gate

Before calling text clipboard support production-ready, the reproducible WeChat Input Method scenario must paste correctly **once**, without extra blank lines, and no clipboard notification may inject a paste. Independently confirm synchronization does not ping-pong.

## References

- [Microsoft MS-RDPECLIP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/)
- [Microsoft clipboard interaction](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeclip/9a784d09-bf53-4362-995d-a20d0eb5f074)
- [Microsoft CF_UNICODETEXT newline convention](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-dclb/53128a2c-84ad-464e-8a12-75c5da932237)


## Implementation checkpoint (2026-11-16)

The CLIPRDR session bridge and format codec are separate modules. The native
macOS clipboard keeps LF; Windows wire text uses CRLF. Format announcements
retain immutable snapshots, and remote text/image formats are retrieved before
one pasteboard update. Native tests cover newline fidelity, mixed formats,
image conversion, echo prevention, and snapshot consistency.

Real-client image transfer and IME regression tests remain open.
