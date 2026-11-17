# ADR-0010 — Independent RDP output and interface scaling

Status: implemented locally (2026-11-16). See the testing guide and the full
Windows regression report for acceptance evidence.

## Decision

RDP transport resolution and the macOS HiDPI logical desktop are independent:

- **RDP output** is an editable, even 16:9 size. It determines the encoded
  surface; changing it restarts the server when running.
- **Interface scale** uses deliberately non-linear levels: **100%, 105%,
  110%, 120%, 135%, 150%, 175%, 200%**. The finer low-end increments are
  intended for small office UI adjustments, with progressively wider high-end
  steps. These are nominal values, not guarantees of an exact pixel scale.
- A resolution resolver prefers existing, real CoreGraphics 2× HiDPI modes.
  Reuse tolerance is an internal, fixed **3%** condition (no UI control),
  measured as maximum *relative effective scale error* on both axes against
  the unrounded mathematical target. Existing modes must retain aspect ratio
  within 0.5% of the source's 16:9 ratio; integer-pixel rounding is allowed.
  Each reused mode must remain closer in actual effective scale to the chosen
  nominal stop than to any other stop, preventing aliasing (e.g. choosing
  105% must not silently reuse a true 100% mode).
- Exact available nominal HiDPI modes take priority; otherwise, choose the
  existing compatible candidate with smallest error (stable tie-break). If
  none qualifies, the fallback mode is rounded to 32×18 logical pixels and
  can be explicitly installed as before. For example, with 2112×1188 RDP
  output, 110% ideally means 1920×1080 logical: an already available
  1866×1050 Retina mode is within the default 3% tolerance and can be reused.
  That 1866×1050 resolution is only *approximately* 16:9, due to rounding.
  The menu shows the *actual* matched resolution/scale.
- Both 2× backing dimension checks must pass. A matching non-HiDPI mode,
  stretched/non-16:9 mode or out-of-tolerance mode cannot be selected
  automatically.
- The editable **RDP resolution** combo box and scale picker are draft-only
  until the user clicks the single context-sensitive button. A missing HiDPI
  mode is created *only* for the selected request after administrator approval.
  If newly defined but not enumerated, the app explicitly requests a macOS
  restart (not an ineffective re-detection command); after reboot the user
  reselects the scale and clicks Apply. If the mode is still not enumerated
  after reboot, the UI reports that the display does not support it.
  Existing modes are never removed.
  Settings persist the nominal percentage (not merely an array index);
  legacy five-step indexes are migrated to the closest new nominal percentage.
  Per-device preferences also retain the nominal choice separately from the
  actual matched Retina mode, so reopening cannot change the visible option.
- Applying a changed RDP output persists the selected HiDPI mode too, then
  restarts the running RDP server once. A scale-only change does not restart
  the RDP surface. Invalid/undersized derived modes are disabled.
- A target absent from the CoreGraphics 2× list is reused only if it passes
  the internal aspect/scale threshold; otherwise it is reported unavailable
  until the user creates the rounded nominal HiDPI mode and macOS loads it
  after a restart. A display override file on disk is *not* evidence of mode
  availability; CoreGraphics enumeration is authoritative.

Desired interface scale and observed macOS display mode are separate state.
Opening the menu reads the saved per-client preference; refreshing actual
display geometry never overwrites a slider choice. A mode rollback is reported
without writing that fallback over the user's saved preference.

## Ownership and data flow

DisplayOutputSettings owns selection and observed display state;
DisplayModeService applies a persistent public CoreGraphics transaction.
DisplayConfigurationStore persists output size, default scale and capture
geometry. ClientDevicePreferences writes per-client output plus HiDPI mode
to the existing locked JSON store.

The native device-display handler restores the remembered mode when the
first client connects. The per-device store also manages remote audio and
publishes the primary client's identity. See [Architecture](../ARCHITECTURE.md#remote-volume).
An explicit offline scale change affects the Mac desktop; background
per-client restoration still happens only on connection, leaving local/UU
automation in charge of its own actions.

FreeRDP Shadow captures the current logical desktop with ScreenCaptureKit,
scales to the independently selected RDP surface while preserving aspect
ratio, and shares the viewport mapping for video and pointer feedback.
Logical mode changes rebuild capture while retaining the RDP output size.

## Optional mode creation and activation limits

The explicitly authorized helper merges full 16-byte 2× HiDPI mode definitions
into the monitor override and backs up the prior file. On the actual AOC
monitor, newly created 1824×1026 and 1760×990 entries were found in the
override (2026-11-17 at 09:58 and 09:59), but were absent from
CGDisplayCopyAllDisplayModes while macOS remained booted since 2026-10-31.
The old private SLSDetectDisplays helper could return success without causing
the new modes to appear. It is no longer a user-visible activation action.

Mode availability is confirmed only by CoreGraphics 2× enumeration. If the
override modification time is newer than the kernel boot time, the UI shows
"restart Mac to load". If an entry predates the boot and still is not
enumerated, the UI reports "unsupported after reboot" rather than repeating
the ineffective activation request. Reboot remains an explicit user choice;
the application does not reboot or unplug displays automatically. Even after
reboot a display/driver can reject a particular custom size.

## Verification

- Historical verification (2026-11-16) established that the **previous**
  five HiDPI targets worked and that Windows mstsc could switch 100%↔120%.
  That does not verify the new Windows-style five-mode plan.
- Swift regression covers both default RDP outputs, the eight nonlinear
  steps, exact-versus-nearby reuse, the synthetic 1080→1050 case, the fixed
  3% runtime threshold (additional 0/1/5% algorithm boundary tests),
  near-16:9 rounding, deliberate rejection of wrong aspect ratio,
  alias prevention, saved-percent migration, the reboot-needed/unsupported
  state machine and kernel boot time vs override modification date.
  Tests inspect actual enumerated 2× metadata without changing the display.
- Windows mstsc acceptance must verify the displayed *actual* scale and
  logical/backing dimensions, including reuse and missing-mode paths.
  Native CTests cover device memory, capture and pointer mapping as before.

Do not introduce a second viewport model, a client-size status file,
or redundant background display-state polling.
