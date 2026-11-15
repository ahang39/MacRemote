# ADR-0008: Embedded Karabiner rule compatibility

Status: Accepted, 2026-11-14. Supersedes ADR-0003's HID-only implementation preference.

## Decision

MacRemote embeds Karabiner basic-rule compatibility directly in its existing macremote-server process. It reads the user's selected Karabiner profile and executes supported rules itself; it does not use the Karabiner app, driver, daemon, EventTap fallback, Hammerspoon, or a separate helper to deliver keyboard input.

Input path: mstsc → FreeRDP macOS native CGEvent → MacRemote native ObjC rule filter → normal Quartz CGEventPost → macOS.

Implementation: src/input/karabiner_compat.m and karabiner_compat.h; native server attaches the filter to the pinned FreeRDP macOS Shadow backend (patches/freerdp-3.33.1-macremote-event-filter.patch). Two other pinned FreeRDP patches preserve left/right modifier bits and reset the backend state after the final RDP client disconnects. tools/build-dev-app.sh reapplies these patches and builds the executable.

## Scope

The actual active configuration has 42 enabled rules, 75 basic manipulators, all parsed (0 skipped). The engine supports:

- Ordered key/button rules, mandatory and optional modifiers, exact left/right flags, optional-any.
- Frontmost application if/unless regular-expression bundle identifiers.
- Key output plus modifier replacement, empty output, mouse buttons and drags, and system-defined Power/Launchpad keys.
- Shell-command actions once per keydown. The four current Hammerspoon Win+Arrow window actions are implemented natively with AppKit/Accessibility (maximize, minimize, left/right half-screen); no Hammerspoon runtime required. The remaining user's shell commands use macOS's built-in shell as configured.
- Selected profile detection, hot reload on JSON file change, preservation of mapping through key-up and reload, Unicode/IME bypass, multiple RDP client key/modifier ownership, disconnect key release.
- No Karabiner config: original Quartz input passes through unchanged, plus release of held keys on disconnect. Native macOS controls and input still work.

This is compatibility with the user's CURRENT Karabiner basic-rule subset, not universal support for every Karabiner feature or direct execution by its internal engine. Future simultaneous, hold-tap, delayed, device-specific, variable and Lua behaviors must be implemented when used. Unknown or corrupt rules are skipped safely rather than silently mapped to something else.

## Tests

An actual FreeRDP production Shadow callback test intercepts CGEventPost at link time so it does not send desktop keystrokes. The native compatibility-engine CTest exercises no-config pass-through and disconnect, currently loaded 75 manipulators, the four native window action classifications, key/modifier remaps, shell commands, frontmost conditions, mouse remap and drag, special key outputs, config reload, Unicode and multi-client modifier union. Check ctest before building a signed App.

End-to-end Windows mstsc acceptance remains to be performed for real window operations, user-input modifiers, mouse gestures, Launchpad, lock screen, Chinese IME and reconnect. Offline tests demonstrate code behavior, not physical HID equivalence or all real-app workflows.

## Maintenance

Source of truth is one Karabiner JSON config. No Apple developer entitlement, third-party helper, or new runtime service is required. Existing FreeRDP dynamic libraries remain MacRemote's pre-existing dependency. Source patching is pinned during build. Karabiner's global CGEventTap fallback must remain off to avoid remapping the output twice.
