# MacRemote engineering guidance

Read README.md, docs/PRD.md, docs/ARCHITECTURE.md, docs/TESTING.md and applicable ADRs before modifying product behavior.

- **Milestone: alpha.** Native Apple Silicon and Intel macOS RDP server using FreeRDP Shadow, AppKit and SwiftUI. macOS account authentication over TLS/PAM is the supported default; ADR-0007 is authoritative.
- Make focused, testable changes. Do not change unrelated software or settings.
- **FreeRDP 3.33.1 is pinned** (ADR-0001/0005). ADR-0007 supersedes the experimental pairing design. Preserve tested authentication, bind defaults and client compatibility.
- **Keyboard integration:** ADR-0008 supersedes ADR-0003. The in-process Karabiner basic-rule compatibility engine reads an existing profile without modifying it; no Karabiner or Hammerspoon runtime dependency is required.
- **UI:** preserve the compact native status item and SwiftUI popover, accessibility, and almond-orange accent. Never display invented performance statistics.
- **Clipboard:** preserve text and image fidelity (ADR-0004); never log clipboard contents or inject unsolicited paste actions.
- **Build:** the standalone development App bundles runtime dependencies. The build may bootstrap pinned third-party sources; it must never start an RDP listener as a side effect.
- **Licensing:** Keep the project LICENSE and bundled third-party license notices intact; upstream code and binaries retain their original licenses. Ad-hoc signed preview binaries must pass transitive dependency auditing and include all license texts. Developer ID signing and notarization remain future milestones.
- Validate behavior with real RDP clients and label unavailable measurements as N/A. Never record or commit credentials, private certificates, unredacted logs or personal environment details.
