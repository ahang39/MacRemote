import CoreGraphics

import Foundation

@main
struct DisplayOutputRegression {
    static func main() {
        let output1080 = DisplaySize(1920, 1080)
        let output1296 = DisplaySize(2304, 1296)
        precondition(DisplaySize(text: "1920 x 1080") == output1080)
        precondition(DisplaySize(text: "2304 × 1296") == output1296)
        precondition(DisplaySize(text: "2560x1440") == DisplaySize(2560, 1440))
        precondition(DisplaySize(text: "3440x1440") == nil)
        precondition(DisplaySize(text: "1921x1080") == nil)

        let first = DisplayScalePlan.modes(base: output1080)
        let second = DisplayScalePlan.modes(base: output1296)
        precondition(DisplayScalePlan.percentages == [100, 105, 110, 120, 135, 150, 175, 200])
        precondition(first.count == 8 && second.count == 8)
        precondition(first == [
            DisplaySize(1920, 1080), DisplaySize(1824, 1026),
            DisplaySize(1760, 990), DisplaySize(1600, 900),
            DisplaySize(1408, 792), DisplaySize(1280, 720),
            DisplaySize(1088, 612), DisplaySize(960, 540)
        ])
        precondition(second == [
            DisplaySize(2304, 1296), DisplaySize(2208, 1242),
            DisplaySize(2080, 1170), DisplaySize(1920, 1080),
            DisplaySize(1696, 954), DisplaySize(1536, 864),
            DisplaySize(1312, 738), DisplaySize(1152, 648)
        ])
        let union = Set(first).union(second)
        precondition(union.count == 15)
        for output in [output1080, output1296] {
            for (step, mode) in DisplayScalePlan.modes(base: output).enumerated() {
                precondition(abs(DisplayScalePlan.percentage(base: output, mode: mode) -
                                 DisplayScalePlan.percentages[step]) <= 2)
            }
        }
        precondition(DisplayScalePlan.modes(base: DisplaySize(800, 450))[7].isValid == false)
        let selected = second[2]
        let empty = Set<DisplaySize>()
        testExistingModeMatching()
        precondition(DisplayChoiceAction.next(target: selected, supported: empty,
                    configured: empty, selectionChanged: true, modeApplied: false) == .install)
        precondition(DisplayChoiceAction.next(target: selected, supported: empty,
                    configured: [selected], selectionChanged: true, modeApplied: false,
                    overrideUpdatedSinceBoot: true) == .restartRequired)
        precondition(DisplayChoiceAction.next(target: selected, supported: empty,
                    configured: [selected], selectionChanged: true, modeApplied: false,
                    overrideUpdatedSinceBoot: false) == .unsupported)
        precondition(DisplayModeService.overrideNeedsRestart(
            modified: Date(timeIntervalSince1970: 200), booted: Date(timeIntervalSince1970: 100)))
        precondition(!DisplayModeService.overrideNeedsRestart(
            modified: Date(timeIntervalSince1970: 100), booted: Date(timeIntervalSince1970: 200)))
        precondition(DisplayChoiceAction.next(target: selected, supported: [selected],
                    configured: empty, selectionChanged: true, modeApplied: true) == .apply)
        precondition(DisplayChoiceAction.next(target: selected, supported: [selected],
                    configured: empty, selectionChanged: false, modeApplied: false) == .apply)
        precondition(DisplayChoiceAction.next(target: selected, supported: [selected],
                    configured: empty, selectionChanged: false, modeApplied: true) == .applied)
        precondition(DisplayChoiceAction.next(target: nil, supported: empty,
                    configured: empty, selectionChanged: true, modeApplied: false) == .invalid)
        let installed = [DisplayModeDefinitions.backingBytes(DisplaySize(1632, 918)),
                         DisplayModeDefinitions.backingBytes(DisplaySize(1408, 792))]
        precondition(DisplayModeDefinitions.contains(DisplaySize(1632, 918), entries: installed))
        precondition(DisplayModeDefinitions.contains(DisplaySize(1408, 792), entries: installed))
        precondition(!DisplayModeDefinitions.contains(DisplaySize(1056, 594), entries: installed))
        // An eight-byte 2x backing entry without the HiDPI flags is incomplete.
        let incomplete = Data(DisplayModeDefinitions.backingBytes(DisplaySize(1632, 918)).prefix(8))
        precondition(!DisplayModeDefinitions.contains(DisplaySize(1632, 918), entries: [incomplete]))
        precondition(first.allSatisfy(\.isValid) && second.allSatisfy(\.isValid))
        precondition(DisplayScalePlan.percentage(base: output1296, mode: DisplaySize(1920, 1080)) == 120)
        precondition(DisplayScalePlan.modes(base: DisplaySize(2560, 1440)).count == 8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemote-display-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "dev.macremote.test.\(UUID().uuidString)")!
        defaults.set("1920 × 1080", forKey: "rdpOutputSize")
        let store = DisplayConfigurationStore(directory: directory, defaults: defaults)
        precondition(store.initialOutput() == output1080)
        precondition(store.runningOutput() == nil)
        try! store.save(output: output1296, scaleStep: 2)
        precondition(store.runningOutput() == output1296)
        precondition(store.initialOutput() == output1296)
        precondition(store.initialScaleStep() == 2)
        precondition(defaults.string(forKey: "rdpOutputSize") == nil)
        precondition(defaults.integer(forKey: "rdpScalePercent") == 110)
        precondition(defaults.object(forKey: "rdpScaleStep") == nil)
        // Old user-visible tolerance preference must no longer influence
        // the internal fixed 3% matching and is dropped on save.
        defaults.set(1, forKey: "rdpReuseTolerancePercent")
        try! store.save(output: output1296, scaleStep: 3)
        precondition(store.initialScaleStep() == 3)
        precondition(defaults.object(forKey: "rdpReuseTolerancePercent") == nil)
        // Legacy five-slot indices retain their previous meaning.
        defaults.removeObject(forKey: "rdpScalePercent")
        defaults.set(2, forKey: "rdpScaleStep")
        precondition(store.initialScaleStep() == 5) // old 150% -> new 150%
        defaults.removeObject(forKey: "rdpScaleStep")
        defaults.set(110, forKey: "rdpScalePercent")
        try! store.save(output: output1296, scaleStep: 2)
        precondition((try! String(contentsOf: store.outputURL, encoding: .utf8))
            == "2304 1296\n")
        try! store.saveCaptureGeometry(displayID: 12, width: 2560, height: 1072)
        precondition((try! String(contentsOf: store.captureLogicalURL, encoding: .utf8))
            == "12 2560 1072\n")
        let preferences = ClientDevicePreferences(directory: directory)
        let currentMode = CGDisplayCopyDisplayMode(CGMainDisplayID())!
        precondition((try! preferences.saveDisplay(output: output1296, mode: currentMode,
                                         previousOutput: store.runningOutput())) == false)
        let active = directory.appendingPathComponent("rdp-active-client.key")
        let firstClient = String(repeating: "a", count: 64)
        let secondClient = String(repeating: "b", count: 64)
        let legacy = [String: [String: Int]](
            uniqueKeysWithValues: [firstClient, secondClient].map {
                ($0, ["logicalWidth": 1920, "logicalHeight": 1080,
                      "renderWidth": 3840, "renderHeight": 2160])
            })
        try! JSONSerialization.data(withJSONObject: legacy).write(
            to: directory.appendingPathComponent("display-by-client.json"))
        try! store.save(output: output1080, scaleStep: 0)
        try! firstClient.write(to: active, atomically: true, encoding: .utf8)
        precondition(try! preferences.saveDisplay(output: output1296, mode: currentMode,
                                         previousOutput: store.runningOutput()))
        let migrated = (try! JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("display-by-client.json"))))
            as! [String: [String: NSNumber]]
        precondition(migrated[firstClient]?["rdpWidth"] == 2304)
        precondition(migrated[secondClient]?["rdpWidth"] == 1920)
        try! store.save(output: output1296, scaleStep: 2)
        try! secondClient.write(to: active, atomically: true, encoding: .utf8)
        precondition(try! preferences.saveDisplay(output: output1080, mode: currentMode,
                                         previousOutput: store.runningOutput()))
        let profileURL = directory.appendingPathComponent("display-by-client.json")
        let profiles = (try! JSONSerialization.jsonObject(with: Data(contentsOf: profileURL)))
            as! [String: [String: NSNumber]]
        precondition(profiles[firstClient]?["rdpWidth"] == 2304)
        precondition(profiles[firstClient]?["rdpHeight"] == 1296)
        precondition(profiles[secondClient]?["rdpWidth"] == 1920)
        precondition(profiles[secondClient]?["rdpHeight"] == 1080)
        precondition(profiles[firstClient]?["logicalWidth"]?.intValue == currentMode.width)
        precondition(preferences.displayProfile(fallbackOutput: store.initialOutput())?.output == output1080)
        precondition(preferences.displayProfile(fallbackOutput: store.initialOutput())?.mode ==
            DisplaySize(currentMode.width, currentMode.height))
        try! firstClient.write(to: active, atomically: true, encoding: .utf8)
        precondition(preferences.displayProfile(fallbackOutput: store.initialOutput())?.output == output1296)
        precondition(store.runningOutput() == output1296)

        let selection = DisplayOutputSettings(configuration: store)
        let storedMode = DisplaySize(currentMode.width, currentMode.height)
        let oldScale = Double(output1296.width) / Double(storedMode.width)
        let savedStep = DisplayScalePlan.modes(base: output1296).enumerated().min {
            abs(Double(output1296.width) / Double($0.element.width) - oldScale) <
            abs(Double(output1296.width) / Double($1.element.width) - oldScale)
        }!.offset
        precondition(selection.outputText == output1296.label)
        precondition(selection.scaleStep == savedStep)
        precondition(selection.draftOutputText == output1296.label)
        precondition(selection.draftScaleStep == savedStep)
        let preview = savedStep == 4 ? 0 : 4
        selection.draftScaleStep = preview
        selection.refreshDisplayState()
        precondition(selection.draftScaleStep == preview)
        precondition(selection.scaleStep == savedStep)
        selection.reloadSelection()
        precondition(selection.draftScaleStep == savedStep)

        if let step = DisplayScalePlan.modes(base: output1296).firstIndex(of: storedMode),
           currentMode.pixelWidth >= currentMode.width * 2 &&
           currentMode.pixelHeight >= currentMode.height * 2 {
            let result = selection.commit(output: output1296.label, step: step,
                                          serverRunning: false)
            precondition(result == .saved)
            precondition(selection.chosenModeApplied)
        }

        // The selected nominal value survives reopening even if the matched
        // logical mode's effective scale differs.
        precondition(try! preferences.saveDisplay(output: output1296, mode: currentMode,
                 previousOutput: output1296, nominalPercent: 105))
        precondition(preferences.displayProfile(fallbackOutput: output1296)?.nominalPercent == 105)
        selection.reloadSelection()
        precondition(selection.scaleStep == 1)
        precondition(selection.draftScaleStep == 1)

        testAudioPreferences(in: directory, mode: currentMode)
        print("display output, nearby HiDPI selection and client preferences: all checks passed")
    }

    private static func testExistingModeMatching() {
        let base = DisplaySize(2112, 1188) // At 110%, ideal logical height is 1080.
        let step = 2
        let near = DisplaySize(1866, 1050) // 2.8% below ideal, near-16:9 pixel rounding.
        let nominal = DisplayScalePlan.modes(base: base)[step]
        precondition(nominal == DisplaySize(1920, 1080))
        precondition(!near.isValid) // Not a creatable exact 16:9 override.
        precondition(DisplayScalePlan.isCompatibleExisting(near, base: base))
        let strict = DisplayScalePlan.resolution(base: base, step: step,
                                                 existing: [near], tolerance: 0)!
        precondition(strict.selected == nominal && !strict.isReused)
        let narrow = DisplayScalePlan.resolution(base: base, step: step,
                                                 existing: [near], tolerance: 1)!
        precondition(narrow.selected == nominal)
        let reuse = DisplayScalePlan.resolution(base: base, step: step,
                                                existing: [near], tolerance: 3)!
        precondition(reuse.selected == near && reuse.isReused)
        precondition(abs(reuse.actualPercent - 113.18) < 0.1)
        precondition(DisplayScalePlan.resolution(base: base, step: step,
                                                 existing: [near, nominal], tolerance: 3)!
                     .selected == nominal)
        precondition(DisplayScalePlan.nearestStep(to: 107.49) == 1)
        precondition(DisplayScalePlan.nearestStep(to: 107.51) == 2)

        let wrongAspect = DisplaySize(1920, 1050)
        precondition(!DisplayScalePlan.isCompatibleExisting(wrongAspect, base: base))
        precondition(DisplayScalePlan.resolution(base: base, step: step,
                    existing: [wrongAspect], tolerance: 5)!.selected == nominal)
        let far = DisplaySize(1728, 972)
        precondition(DisplayScalePlan.resolution(base: base, step: step,
                    existing: [far], tolerance: 5)!.selected == nominal)
        let smallest = DisplaySize(800, 450)
        precondition(DisplayScalePlan.resolution(base: smallest, step: 7,
                    existing: [], tolerance: 3) == nil)
        precondition(DisplayScalePlan.resolution(base: base, step: 2,
                    existing: [], tolerance: 2) == nil)

        // Even a generous 5% tolerance cannot alias 105% to the 100% mode.
        let output = DisplaySize(2304, 1296)
        precondition(DisplayScalePlan.resolution(base: output, step: 1,
                    existing: [output], tolerance: 5)!.selected != output)
        precondition(DisplayScalePlan.resolution(base: output, step: 3,
                    existing: [DisplaySize(1920, 1080)], tolerance: 3)!
                     .selected == DisplaySize(1920, 1080))
        // Check real display mode metadata; only genuine 2x backing is eligible.
        let service = DisplayModeService()
        let available = service.availableModes()
        let supported = Set(available.compactMap(\.hiDPISize))
        precondition(supported.allSatisfy { size in
            available.contains { mode in
                mode.width == size.width && mode.height == size.height &&
                    mode.pixelWidth == size.width * 2 && mode.pixelHeight == size.height * 2
            }
        })
        print("nearby mode matching: 0/1/3/5%, aspect, alias protection, real 2x modes passed")
    }

    private static func testAudioPreferences(in directory: URL, mode: CGDisplayMode) {
        let preferences = ClientDevicePreferences(directory: directory)
        let marker = directory.appendingPathComponent("rdp-active-client.key")
        let profile = directory.appendingPathComponent("display-by-client.json")
        let first = String(repeating: "c", count: 64)
        let second = String(repeating: "d", count: 64)
        let pid: Int32 = 123
        func connect(_ key: String) {
            try! "\(key)\n\(pid)\n".write(to: marker, atomically: true, encoding: .utf8)
        }
        func audio() -> ClientDevicePreferences.Audio {
            preferences.activeClient(serverPID: pid)!.audio
        }
        func write(_ change: ClientDevicePreferences.Change, for key: String) {
            precondition(try! preferences.update(change, for: key, serverPID: pid) != nil)
        }

        let legacy = ["logicalWidth": mode.width, "logicalHeight": mode.height,
                      "renderWidth": mode.pixelWidth, "renderHeight": mode.pixelHeight,
                      "futureField": 9]
        try! JSONSerialization.data(withJSONObject: [first: legacy]).write(to: profile)
        connect(first)
        precondition(audio().volume == 100 && !audio().muted)
        precondition(preferences.activeClient(serverPID: pid)?.bitrate == .high)
        write(.bitrate(.low), for: first)
        precondition(preferences.activeClient(serverPID: pid)?.bitrate == .low)
        precondition(try! preferences.update(.bitrate(.medium), for: second, serverPID: pid) == nil)
        precondition(preferences.activeClient(serverPID: nil) == nil)
        precondition(preferences.activeClient(serverPID: pid + 1) == nil)

        write(.volume(-5), for: first)
        precondition(audio().volume == 0 && !audio().muted)
        write(.volume(105), for: first)
        precondition(audio().volume == 100)
        write(.volume(37), for: first)
        write(.toggleMute, for: first)
        precondition(audio().volume == 37 && audio().muted)
        let output = DisplaySize(2304, 1296)
        precondition(try! preferences.saveDisplay(output: output, mode: mode,
                                                  previousOutput: DisplaySize(1920, 1080)))
        let stored = try! JSONSerialization.jsonObject(with: Data(contentsOf: profile))
            as! [String: [String: NSNumber]]
        precondition(stored[first]?["audioVolume"] == 37)
        precondition(stored[first]?["audioMuted"] == true)
        precondition(stored[first]?["futureField"] == 9)
        precondition(stored[first]?["renderWidth"]?.intValue == mode.pixelWidth)
        precondition(stored[first]?["rdpWidth"] == 2304)

        connect(second)
        precondition(audio().volume == 100 && !audio().muted)
        precondition(try! preferences.update(.volume(12), for: first, serverPID: pid) == nil)
        write(.volume(72), for: second)
        precondition(audio().volume == 72 && !audio().muted)
        try! second.write(to: marker, atomically: true, encoding: .utf8)
        precondition(preferences.activeClient(serverPID: pid) == nil)
        precondition(try! preferences.update(.toggleMute, for: second, serverPID: pid) == nil)

        connect(first)
        precondition(audio().volume == 37 && audio().muted)
        write(.toggleMute, for: first)
        precondition(audio().volume == 37 && !audio().muted)
        connect(second)
        precondition(audio().volume == 72 && !audio().muted)
        precondition(preferences.displayProfile(fallbackOutput: output) == nil)

        let corrupt = Data("corrupt".utf8)
        try! corrupt.write(to: profile)
        do {
            _ = try preferences.update(.volume(1), for: second, serverPID: pid)
            preconditionFailure("Overwrote a corrupt profile")
        } catch {
            precondition(try! Data(contentsOf: profile) == corrupt)
        }
    }
}
