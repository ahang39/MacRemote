import CoreGraphics
import Foundation
import Combine

@MainActor
final class DisplayOutputSettings: ObservableObject {
    static let shared = DisplayOutputSettings()

    @Published var outputText: String
    @Published var scaleStep: Int
    @Published var draftOutputText: String
    @Published var draftScaleStep: Int
    private let reuseTolerancePercent = DisplayScalePlan.defaultReuseTolerance
    @Published var message: String?
    @Published private var observedMode: CGDisplayMode?
    @Published private(set) var offeredSizes: [String] = []
    @Published var isActivating = false
    @Published private(set) var availableHiDPIModes: Set<DisplaySize> = []
    private var configuredModeEntries: [Data] = []
    private var overrideUpdatedSinceBoot = true

    var actualMode: DisplaySize? { observedMode?.logicalSize }

    private let configuration: DisplayConfigurationStore
    private let modeService = DisplayModeService()
    private let preferences: ClientDevicePreferences
    private var modeVerification: DispatchWorkItem?

    private func validateDisplaySwitch(_ expected: DisplaySize) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.modeVerification = nil
            self.refreshDisplayState()
            if self.observedMode?.hiDPISize != expected {
                self.message = "macOS reverted to \(self.actualMode?.label ?? "unknown"). " +
                    "Your selected \(expected.label) HiDPI preference is preserved."
            }
        }
        modeVerification = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
    }

    var chosenOutput: DisplaySize? { DisplaySize(text: outputText) }
    var modes: [DisplaySize] { chosenOutput.map { DisplayScalePlan.modes(base: $0) } ?? [] }
    var chosenMode: DisplaySize? {
        chosenOutput.flatMap {
            DisplayScalePlan.resolution(base: $0, step: scaleStep,
                existing: availableHiDPIModes, tolerance: reuseTolerancePercent)?.selected
        }
    }

    func resolvedScale(output: String, step: Int) -> DisplayScaleResolution? {
        DisplaySize(text: output).flatMap {
            DisplayScalePlan.resolution(base: $0, step: step,
                existing: availableHiDPIModes,
                tolerance: DisplayScalePlan.defaultReuseTolerance)
        }
    }

    init(configuration: DisplayConfigurationStore = DisplayConfigurationStore()) {
        self.configuration = configuration
        preferences = ClientDevicePreferences(directory: configuration.directory)
        let output = configuration.initialOutput()
        let savedStep = Self.savedScaleStep(for: output, configuration: configuration)
        outputText = output.label
        scaleStep = savedStep
        draftOutputText = output.label
        draftScaleStep = savedStep
        refreshDisplayState()
        if let mode = chosenMode, !availableHiDPIModes.contains(mode) {
            message = "HiDPI mode \(mode.label) is not available. Select it to see the required action."
        }
    }

    private static func savedScaleStep(for output: DisplaySize,
                                       configuration: DisplayConfigurationStore) -> Int {
        let preferences = ClientDevicePreferences(directory: configuration.directory)
        if let profile = preferences.displayProfile(fallbackOutput: output), profile.output == output {
            if let percent = profile.nominalPercent,
               let step = DisplayScalePlan.percentages.firstIndex(of: percent) {
                return step
            }
            let choices = DisplayScalePlan.modes(base: output)
            // Preserve the visual size of previously saved legacy HiDPI modes.
            if let exact = choices.firstIndex(of: profile.mode) { return exact }
            guard profile.mode.width > 0 else { return configuration.initialScaleStep() }
            let previous = Double(output.width) / Double(profile.mode.width)
            return choices.indices.min(by: {
                abs(log(Double(output.width) / Double(choices[$0].width) / previous)) <
                abs(log(Double(output.width) / Double(choices[$1].width) / previous))
            }) ?? configuration.initialScaleStep()
        }
        return configuration.initialScaleStep()
    }

    func reloadSelection() {
        let output = configuration.initialOutput()
        outputText = output.label
        scaleStep = Self.savedScaleStep(for: output, configuration: configuration)
        draftOutputText = outputText
        draftScaleStep = scaleStep
        refreshDisplayState()
    }

    func refreshDisplayState() {
        let availableModes = modeService.availableModes()
        let resolutions = Set(availableModes.map(\.logicalSize).filter(\.isValid))
        offeredSizes = resolutions.isEmpty
            ? ["2304 × 1296", "1920 × 1080"]
            : resolutions.sorted(by: >).map(\.label)
        observedMode = CGDisplayCopyDisplayMode(CGMainDisplayID())

        let entries = modeService.configuredModeEntries()
        let supported = Set(availableModes.compactMap(\.hiDPISize))
        availableHiDPIModes = supported
        configuredModeEntries = entries
        overrideUpdatedSinceBoot = modeService.overrideUpdatedSinceBoot()
    }

    var chosenModeApplied: Bool {
        guard let mode = chosenMode else { return false }
        return mode == observedMode?.hiDPISize
    }

    func action(for output: String, step: Int) -> DisplayChoiceAction {
        let choice = resolvedScale(output: output, step: step)
        return DisplayChoiceAction.next(
            target: choice?.selected, supported: availableHiDPIModes,
            configured: choice.map {
                DisplayModeDefinitions.contains($0.selected, entries: configuredModeEntries)
                    ? [$0.selected] : []
            } ?? [],
            selectionChanged: DisplaySize(text: output) != chosenOutput || step != scaleStep,
            modeApplied: observedMode?.hiDPISize == choice?.selected,
            overrideUpdatedSinceBoot: overrideUpdatedSinceBoot)
    }

    enum CommitResult {
        case rejected
        case saved
        case applied
        case restartRequired
    }

    @discardableResult
    func commit(output: String, step: Int, serverRunning: Bool) -> CommitResult {
        guard let base = DisplaySize(text: output) else {
            outputText = configuration.initialOutput().label
            refreshDisplayState()
            message = "Use a valid 16:9 resolution, e.g. 2304 × 1296 or 2560 × 1440."
            return .rejected
        }

        guard let resolved = resolvedScale(output: output, step: step) else {
            message = "Invalid scaling level."
            return .rejected
        }
        let previousOutput = configuration.runningOutput()
        let target = resolved.selected
        guard let nativeMode = modeService.supportedHiDPI(target) else {
            refreshDisplayState()
            message = "HiDPI mode \(target.label) is unavailable. Create it or restart macOS to load it."
            return .rejected
        }

        var savedForClient = false
        do {
            savedForClient = try preferences.saveDisplay(output: base, mode: nativeMode,
                                                           previousOutput: previousOutput,
                                                           nominalPercent: DisplayScalePlan.percentages[step])
            try configuration.save(output: base, scaleStep: step)
        } catch {
            outputText = configuration.initialOutput().label
            refreshDisplayState()
            message = "Could not save display preference: \(error.localizedDescription)"
            return .rejected
        }

        modeVerification?.cancel()
        modeVerification = nil
        outputText = base.label
        scaleStep = step
        refreshDisplayState()

        let outputChanged = previousOutput != base
        let current = observedMode
        if current?.width == nativeMode.width &&
            current?.height == nativeMode.height &&
            current?.pixelWidth == nativeMode.pixelWidth &&
            current?.pixelHeight == nativeMode.pixelHeight {
            message = savedForClient
                ? "Display preference saved for this device."
                : "Display preference saved."
            if resolved.isReused {
                message = "Reused existing \(target.label) HiDPI " +
                    "(actual \(String(format: "%.1f", resolved.actualPercent))% scale)."
            }
            return outputChanged && serverRunning ? .restartRequired : .saved
        }

        guard modeService.applyPersistentMode(nativeMode) == .success else {
            refreshDisplayState()
            message = "RDP output saved, but macOS rejected \(target.label) HiDPI."
            return outputChanged && serverRunning ? .restartRequired : .rejected
        }

        do {
            try configuration.saveCaptureGeometry(
                displayID: CGMainDisplayID(), width: nativeMode.width, height: nativeMode.height)
            message = "Display: \(target.label) HiDPI · RDP output: \(base.label)" +
                (resolved.isReused
                    ? " · Reused (\(String(format: "%.1f", resolved.actualPercent))%)" : "")
        } catch {
            message = "Display mode changed, but capture geometry could not be synchronized."
        }
        refreshDisplayState()
        validateDisplaySwitch(target)
        return outputChanged && serverRunning ? .restartRequired : .applied
    }

    func requestMissingModeInstallation(output: String, step: Int) {
        refreshDisplayState()
        guard !isActivating, action(for: output, step: step) == .install,
              let target = resolvedScale(output: output, step: step)?.selected else { return }
        isActivating = true
        message = "Requesting administrator authorization for \(target.label) HiDPI…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: String
            do {
                try DisplayModeOperations.install([target])
                result = "HiDPI mode \(target.label) saved. Restart macOS to load the new resolution."
            } catch {
                result = "Install not completed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshDisplayState()
                self.isActivating = false
                self.message = result
            }
        }
    }

}
