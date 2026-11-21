import CoreGraphics
import Foundation
import Darwin

struct DisplayModeService {
    // WindowServer can revert a transient CGDisplaySetDisplayMode call.
    func applyPersistentMode(_ mode: CGDisplayMode) -> CGError {
        let display = CGMainDisplayID()
        // BetterDisplay/other virtual display modes belong to their creator.
        let isVirtual = CGDisplayModelNumber(display) == 0x76697274 ||
            (CGDisplayVendorNumber(display) == 0x4d52 &&
             CGDisplayModelNumber(display) == 0x4844)
        if isVirtual { return .failure }
        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else {
            return begun == .success ? .failure : begun
        }
        let result = CGConfigureDisplayWithDisplayMode(
            config, CGMainDisplayID(), mode, nil)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return result
        }
        return CGCompleteDisplayConfiguration(config, .permanently)
    }

    func availableModes() -> [CGDisplayMode] {
        let options: CFDictionary = [
            kCGDisplayShowDuplicateLowResolutionModes as String: true
        ] as CFDictionary
        return CGDisplayCopyAllDisplayModes(
            CGMainDisplayID(), options) as? [CGDisplayMode] ?? []
    }

    func supportedHiDPI(_ target: DisplaySize) -> CGDisplayMode? {
        let refresh = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 60
        return availableModes()
            .filter { $0.hiDPISize == target }
            .min { abs($0.refreshRate - refresh) < abs($1.refreshRate - refresh) }
    }

    private func overridePath() -> String? {
        let display = CGMainDisplayID()
        let vendor = CGDisplayVendorNumber(display)
        let product = CGDisplayModelNumber(display)
        guard vendor > 0 && product > 0 else { return nil }
        return String(format:
            "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x/DisplayProductID-%x",
            vendor, product)
    }

    func configuredModeEntries() -> [Data] {
        guard let path = overridePath(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dictionary = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let definitions = dictionary["scale-resolutions"] as? [Data]
        else { return [] }
        return definitions
    }

    static func overrideNeedsRestart(modified: Date, booted: Date) -> Bool {
        modified >= booted
    }

    func overrideUpdatedSinceBoot() -> Bool {
        // If metadata cannot be obtained, prefer the conservative restart
        // guidance over an unsupported verdict.
        guard let path = overridePath(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return true }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return true }
        return Self.overrideNeedsRestart(
            modified: modified,
            booted: Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)))
    }
}

extension CGDisplayMode {
    var logicalSize: DisplaySize { DisplaySize(width, height) }
    var hiDPISize: DisplaySize? {
        pixelWidth == width * 2 && pixelHeight == height * 2 ? logicalSize : nil
    }
}
