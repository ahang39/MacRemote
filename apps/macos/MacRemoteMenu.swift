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
    private var displayActionLabel: String {
        switch displayAction {
        case .invalid: return "Choose a valid resolution"
        case .install: return "Create \(draftMode?.label ?? "selected") HiDPI…"
        case .restartRequired: return "Restart Mac to load HiDPI"
        case .unsupported: return "HiDPI unavailable"
        case .apply: return "Apply display settings"
        case .applied: return "Display settings applied"
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

    private var remoteVolumeRow: some View {
        let selection = remote.selection
        let volume = selection?.audio.volume ?? 100
        let muted = selection?.audio.muted ?? false

        return HStack(spacing: 8) {
            Button {
                remote.update(.toggleMute, for: selection?.key, serverPID: controller.servingProcessID)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" :
                        volume == 0 ? "speaker.fill" : "speaker.wave.2.fill")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(accent)
            .accessibilityLabel(muted ? "Unmute remote audio" : "Mute remote audio")

            Text("Remote volume")
            Slider(
                value: Binding(
                    get: { Double(volume) },
                    set: {
                        let percent = Int($0.rounded())
                        guard percent != volume else { return }
                        remote.update(.volume(percent), for: selection?.key,
                                     serverPID: controller.servingProcessID)
                    }
                ),
                in: 0...100
            )
            .tint(accent)
            .accessibilityLabel("Remote volume")
            .accessibilityValue(muted ? "\(volume) percent, muted" : "\(volume) percent")
            Text("\(volume)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 35, alignment: .trailing)
        }
        .font(.callout)
        .disabled(selection == nil)
        .id(selection?.key)
    }

    private var videoBitrateRow: some View {
        let selection = remote.selection
        return HStack(spacing: 12) {
            Label("Video target", systemImage: "gauge.with.dots.needle.33percent")
            Spacer(minLength: 0)
            Picker("AVC420 video target (Mbps)", selection: Binding(
                get: { selection?.bitrate ?? .high },
                set: { remote.update(.bitrate($0), for: selection?.key,
                                     serverPID: controller.servingProcessID) }
            )) {
                ForEach(ClientDevicePreferences.VideoBitrate.allCases, id: \.self) { target in
                    Text(target.label)
                        .accessibilityLabel("\(target.label) megabits per second")
                        .tag(target)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 142)
            Text("Mbps")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .disabled(selection == nil || !controller.isServingH264)
        .help("Average video encoder target for the connected device’s AVC420 session.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 24))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacRemote")
                        .font(.system(.headline, design: .rounded))
                    Text(controller.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(controller.isRunning ? .green : .gray)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }

            Divider()
            HStack {
                Label("Mac login", systemImage: "person.crop.circle")
                Spacer()
                Text(controller.account)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack {
                Label("Authentication", systemImage: "lock")
                Spacer()
                Text("TLS + Mac password")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack {
                Label("Listen port", systemImage: "network")
                Spacer()
                TextField("Port", text: $controller.port)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("RDP listen port")
                    .accessibilityHint("Set the TCP port while the server is stopped")
                    .disabled(controller.wantsServer)
            }
            .font(.callout)

            HStack {
                Label("Screen recording", systemImage: "rectangle.on.rectangle")
                Spacer()
                Text(controller.screenCaptureGranted.map { $0 ? "Granted" : "Permission needed" }
                     ?? "Unavailable")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Divider()

            HStack(spacing: 8) {
                Label("RDP resolution", systemImage: "display")
                Spacer()
                EditableResolutionComboBox(
                    value: $display.draftOutputText,
                    options: display.offeredSizes
                ) { display.draftOutputText = $0 }
                .frame(width: 151, height: 26)
                .accessibilityLabel("RDP output resolution. Select or type width by height")
            }
            .font(.callout)

            HStack(spacing: 8) {
                Label("Mac UI scale", systemImage: "textformat.size")
                Spacer()
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
                .frame(width: 171)
                .accessibilityLabel("Mac interface scale")
                .help("Non-linear scale levels. Existing close-enough HiDPI modes are preferred.")
            }
            .font(.callout)

            if let matched = draftMatch, matched.isReused {
                Text("Using existing \(matched.selected.label) HiDPI · actual " +
                     "\(String(format: "%.1f", matched.actualPercent))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if displayAction == .restartRequired {
                Label("HiDPI \(draftMode?.label ?? "mode") created · restart Mac to load",
                      systemImage: "arrow.clockwise.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("After restarting macOS, select this scale again and apply it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if displayAction == .unsupported {
                Label("macOS did not load \(draftMode?.label ?? "this") HiDPI mode",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("The mode is defined but still unavailable after reboot. Choose another scale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: performDisplayAction) {
                    Label(display.isActivating ? "Creating HiDPI mode…" : displayActionLabel,
                          systemImage: displayAction == .install ? "plus.circle" : "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
                .disabled(display.isActivating || displayAction == .invalid || displayAction == .applied)
            }

            if displayAction == .install {
                Text("This mode requires one-time administrator authorization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if displayAction == .apply && draftBase != display.chosenOutput && controller.isRunning {
                Text("Applying a new RDP resolution will restart the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if displayAction == .invalid {
                Text("Enter an even 16:9 resolution; smaller outputs may not support every scale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let actual = display.actualMode, displayAction != .applied {
                Text("Current Mac desktop: \(actual.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            videoBitrateRow
            remoteVolumeRow
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

            Button {
                if controller.wantsServer { controller.stop() }
                else { controller.start() }
            } label: {
                Label(
                    controller.wantsServer ? "Stop RDP server" : "Start RDP server",
                    systemImage: controller.wantsServer ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)

            HStack {
                Button("Refresh") { controller.refresh() }
                if controller.screenCaptureGranted == false {
                    Button("Enable Screen Recording") {
                        controller.requestScreenCapturePermission()
                    }
                }
                Spacer()
                Button("Quit") {
                    controller.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .frame(width: 335)
        .padding(16)
        .onAppear { display.reloadSelection() }
        .onChange(of: display.draftOutputText) { _, _ in display.message = nil }
        .onChange(of: display.draftScaleStep) { _, _ in display.message = nil }
        .task {
            while !Task.isCancelled {
                remote.refresh(serverPID: controller.servingProcessID)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .onChange(of: controller.servingProcessID) { _, pid in remote.refresh(serverPID: pid) }
    }
}

@MainActor
private final class RemoteClientSettings: ObservableObject {
    static let shared = RemoteClientSettings()
    @Published private(set) var selection: ClientDevicePreferences.ActiveClient?
    @Published private(set) var errorText: String?
    private let preferences = ClientDevicePreferences(directory: DisplayConfigurationStore().directory)

    func refresh(serverPID: Int32?) {
        let current = preferences.activeClient(serverPID: serverPID)
        if current?.key != selection?.key { errorText = nil }
        if current != selection { selection = current }
    }

    func update(_ change: ClientDevicePreferences.Change, for key: String?,
                serverPID: Int32?) {
        guard let key, let pid = serverPID else {
            refresh(serverPID: serverPID)
            return
        }
        do {
            if let updated = try preferences.update(change, for: key, serverPID: pid) {
                selection = updated
                errorText = nil
            } else {
                refresh(serverPID: serverPID)
            }
        } catch {
            errorText = "Could not save remote setting: \(error.localizedDescription)"
            refresh(serverPID: serverPID)
        }
    }
}
