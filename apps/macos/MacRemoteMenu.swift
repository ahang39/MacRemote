import AppKit
import Combine
import SwiftUI

struct MacRemoteMenu: View {
    @ObservedObject private var controller = MacRemoteController.shared
    @ObservedObject private var display = DisplayOutputSettings.shared
    @ObservedObject private var remote = RemoteClientSettings.shared

    private let accent = Color(red: 0.831, green: 0.529, blue: 0.322)

    private var draftOutput: String { display.draftOutputText }
    private var draftScaleStep: Int { display.draftScaleStep }
    private var draftBase: DisplaySize? { DisplaySize(text: draftOutput) }
    private var draftMatch: DisplayScaleResolution? {
        display.resolvedScale(output: draftOutput, step: draftScaleStep)
    }
    private var draftMode: DisplaySize? { draftMatch?.selected }
    private var displayAction: DisplayChoiceAction {
        display.action(for: draftOutput, step: draftScaleStep)
    }

    private var activeBandwidthMode: BandwidthMode {
        remote.selection?.bandwidthMode ?? controller.defaultBandwidthMode
    }

    private var displayActionLabel: String {
        switch displayAction {
        case .invalid: "Invalid resolution"
        case .install: "Create \(draftMode?.label ?? "selected") HiDPI…"
        case .restartRequired: "Restart Mac to load HiDPI"
        case .unsupported: "HiDPI unavailable"
        case .apply: "Apply display settings"
        case .applied: "Applied"
        }
    }

    private func performDisplayAction() {
        switch displayAction {
        case .install:
            display.requestMissingModeInstallation(output: draftOutput, step: draftScaleStep)
        case .apply:
            if display.commit(output: draftOutput, step: draftScaleStep,
                              serverRunning: controller.isRunning) == .restartRequired {
                controller.restartForOutputChange()
            }
        case .invalid, .applied, .restartRequired, .unsupported:
            break
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacRemote")
                    .font(.system(.headline, design: .rounded))
                Text("\(controller.statusText) · \(controller.account)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("RDP server", isOn: Binding(
                get: { controller.wantsServer },
                set: { enabled in
                    if enabled { controller.start() } else { controller.stop() }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(accent)
            .accessibilityLabel("RDP server")
            .accessibilityValue(controller.isRunning ? "Running" : "Stopped")
        }
    }

    @ViewBuilder private var permissionBanner: some View {
        if controller.screenCaptureGranted == false {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text("Screen Recording permission required")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Button("Enable") { controller.requestScreenCapturePermission() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var telemetrySummary: String? {
        guard remote.selection != nil else { return nil }
        guard let session = remote.session else { return "Connecting…" }
        if session.codec == nil {
            return "Waiting for frame…"
        }
        if session.totalBytesPerSec == 0 && session.fps == 0 {
            return "Idle · 0 KB/s"
        }
        var parts = [session.formattedRate, "\(session.fps) fps"]
        if let rtt = session.ackRttMs {
            parts.append("\(rtt) ms")
        }
        return parts.joined(separator: " · ")
    }

    private var sessionCard: some View {
        let selection = remote.selection
        let session = remote.session
        let connected = selection != nil
        let volume = selection?.audio.volume ?? 100
        let muted = selection?.audio.muted ?? false
        let mode = activeBandwidthMode

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green :
                          (controller.isRunning ? accent.opacity(0.7) : Color.secondary.opacity(0.4)))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(connected ? "Connected" :
                     (controller.isRunning ? "Waiting for client" : "Server stopped"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(connected ? .primary : .secondary)
                Spacer(minLength: 6)
                if let telemetry = telemetrySummary {
                    Text(telemetry)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Server outbound payload (video + audio), sent FPS, and RDPGFX frame-ACK RTT.")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Picker("Bandwidth mode", selection: Binding(
                    get: { mode },
                    set: { next in
                        if let selection {
                            remote.update(.bandwidth(next), for: selection.key,
                                          serverPID: controller.servingProcessID,
                                          defaultMode: controller.defaultBandwidthMode)
                        } else {
                            controller.defaultBandwidthMode = next
                        }
                    }
                )) {
                    ForEach(BandwidthMode.allCases) { option in
                        Text(option.shortLabel).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Bandwidth mode")

                if let session, session.isLegacyColorDepth {
                    Text("16-bit client · Reconnect with 32-bit color for H.264.")
                        .font(.caption2)
                        .foregroundStyle(accent)
                } else {
                    Text("\(mode.summary) · \(connected ? "This device" : "Default for new devices")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    remote.update(.toggleMute, for: selection?.key,
                                  serverPID: controller.servingProcessID,
                                  defaultMode: controller.defaultBandwidthMode)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" :
                            volume == 0 ? "speaker.fill" : "speaker.wave.2.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(connected ? accent : .secondary)
                .accessibilityLabel(muted ? "Unmute remote audio" : "Mute remote audio")

                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: {
                            let percent = Int($0.rounded())
                            guard percent != volume else { return }
                            remote.update(.volume(percent), for: selection?.key,
                                          serverPID: controller.servingProcessID,
                                          defaultMode: controller.defaultBandwidthMode)
                        }
                    ),
                    in: 0...100
                )
                .tint(accent)
                .accessibilityLabel("Remote volume")
                .accessibilityValue(muted ? "\(volume) percent, muted" : "\(volume) percent")

                Text("\(volume)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            .disabled(!connected)
            .opacity(connected ? 1 : 0.55)
            .id(selection?.key)
        }
        .padding(11)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Display")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let actual = display.actualMode {
                    Text("Mac \(actual.label)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                Label("Output", systemImage: "display")
                Spacer(minLength: 4)
                EditableResolutionComboBox(
                    value: $display.draftOutputText,
                    options: display.offeredSizes
                ) { display.draftOutputText = $0 }
                .frame(width: 148, height: 24)
                .accessibilityLabel("RDP output resolution. Select or type width by height")
            }
            .font(.callout)

            HStack(spacing: 8) {
                Label("UI scale", systemImage: "textformat.size")
                Spacer(minLength: 4)
                Picker("Mac UI scale", selection: $display.draftScaleStep) {
                    ForEach(DisplayScalePlan.percentages.indices, id: \.self) { step in
                        let choice = display.resolvedScale(output: draftOutput, step: step)
                        Text("\(DisplayScalePlan.percentages[step])% · \(choice?.selected.label ?? "—")")
                            .tag(step)
                            .disabled(choice == nil)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 164)
                .accessibilityLabel("Mac interface scale")
                .help("Non-linear scale levels. Existing close-enough HiDPI modes are preferred.")
            }
            .font(.callout)

            if let matched = draftMatch, matched.isReused {
                Text("Reusing \(matched.selected.label) HiDPI (\(String(format: "%.1f", matched.actualPercent))%)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            displayActionView
        }
        .padding(11)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var displayActionView: some View {
        switch displayAction {
        case .applied:
            EmptyView()
        case .restartRequired:
            VStack(alignment: .leading, spacing: 2) {
                Label("HiDPI \(draftMode?.label ?? "mode") created · restart Mac to load",
                      systemImage: "arrow.clockwise.circle")
                    .font(.caption)
                    .foregroundStyle(accent)
                Text("After restarting macOS, select this scale again and apply it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .unsupported:
            VStack(alignment: .leading, spacing: 2) {
                Label("macOS did not load \(draftMode?.label ?? "this") HiDPI mode",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Choose another scale.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .invalid:
            Text("Enter an even 16:9 resolution (e.g. 1920 × 1080 or 2304 × 1296).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .install, .apply:
            VStack(alignment: .leading, spacing: 4) {
                Button(action: performDisplayAction) {
                    Label(display.isActivating ? "Creating HiDPI mode…" : displayActionLabel,
                          systemImage: displayAction == .install ? "plus.circle" : "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.regular)
                .disabled(display.isActivating)

                if displayAction == .install {
                    Text("Requires one-time administrator authorization.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if draftBase != display.chosenOutput && controller.isRunning {
                    Text("Applying a new output resolution restarts the RDP server.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serverDisclosure: some View {
        DisclosureGroup(isExpanded: $remote.serverDetailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Listen port", systemImage: "network")
                    Spacer()
                    TextField("Port", text: $controller.port)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("RDP listen port")
                        .accessibilityHint("Stop the server before changing the TCP port")
                        .disabled(controller.wantsServer)
                }
                HStack {
                    Label("Authentication", systemImage: "lock")
                    Spacer()
                    Text("TLS + Mac password")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Screen recording", systemImage: "record.circle")
                    Spacer()
                    Text(controller.screenCaptureGranted.map { $0 ? "Granted" : "Needed" }
                         ?? "Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Server settings")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("TCP \(controller.port) · TLS + PAM")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            headerBar
            permissionBanner
            sessionCard
            displayCard
            serverDisclosure

            if let error = remote.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let detail = display.message {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = controller.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()

            HStack {
                Button("Refresh") {
                    controller.refresh()
                    display.refreshDisplayState()
                }
                Spacer()
                Button("Quit") {
                    controller.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(width: 332)
        .padding(14)
        .onAppear { display.reloadSelection() }
        .onChange(of: display.draftOutputText) { _, _ in display.message = nil }
        .onChange(of: display.draftScaleStep) { _, _ in display.message = nil }
        .task {
            while !Task.isCancelled {
                remote.refresh(serverPID: controller.servingProcessID,
                               defaultMode: controller.defaultBandwidthMode)
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        .onChange(of: controller.servingProcessID) { _, pid in
            remote.refresh(serverPID: pid, defaultMode: controller.defaultBandwidthMode)
        }
    }
}

@MainActor
private final class RemoteClientSettings: ObservableObject {
    static let shared = RemoteClientSettings()
    @Published var serverDetailsExpanded = false
    @Published private(set) var selection: ClientDevicePreferences.ActiveClient?
    @Published private(set) var session: ClientDevicePreferences.SessionStatus?
    @Published private(set) var errorText: String?
    private let preferences = ClientDevicePreferences(directory: DisplayConfigurationStore().directory)

    func refresh(serverPID: Int32?, defaultMode: BandwidthMode) {
        let current = preferences.activeClient(serverPID: serverPID, defaultMode: defaultMode)
        if current?.key != selection?.key { errorText = nil }
        if current != selection { selection = current }
        let next = preferences.sessionStatus(serverPID: serverPID)
        if session != next { session = next }
    }

    @discardableResult
    func update(_ change: ClientDevicePreferences.Change, for key: String?,
                serverPID: Int32?, defaultMode: BandwidthMode) -> Bool {
        guard let key, let pid = serverPID else {
            refresh(serverPID: serverPID, defaultMode: defaultMode)
            return false
        }
        do {
            if let updated = try preferences.update(change, for: key, serverPID: pid,
                                                    defaultMode: defaultMode) {
                selection = updated
                errorText = nil
                return true
            } else {
                refresh(serverPID: serverPID, defaultMode: defaultMode)
                return false
            }
        } catch {
            errorText = "Could not save remote setting: \(error.localizedDescription)"
            refresh(serverPID: serverPID, defaultMode: defaultMode)
            return false
        }
    }
}
