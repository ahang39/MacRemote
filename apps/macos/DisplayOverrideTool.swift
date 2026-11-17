import CoreGraphics
import Foundation
import Darwin

enum DisplayOverrideInstaller {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2, arguments[0] == "install" || arguments[0] == "plan" else {
            throw NSError(domain: "MacRemote Display Modes", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Usage: macremote-display-overrides plan|install WxH [WxH...]"])
        }
        let operation = arguments[0]
        let sizes = try arguments.dropFirst().map { text -> (Int, Int) in
            let parts = text.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                  w >= 800, h >= 450, w <= 4096, h <= 2160,
                  w % 2 == 0, h % 2 == 0, 9 * w == 16 * h else {
                throw NSError(domain: "MacRemote Display Modes", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid 16:9 resolution: \(text)"])
            }
            return (w, h)
        }
        let display = CGMainDisplayID()
        let vendor = Int(CGDisplayVendorNumber(display))
        let product = Int(CGDisplayModelNumber(display))
        guard vendor > 0, product > 0 else {
            throw NSError(domain: "MacRemote Display Modes", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to identify physical display."])
        }
        let suffix = String(format: "DisplayVendorID-%x/DisplayProductID-%x", vendor, product)
        let root = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")
        let file = root.appendingPathComponent(suffix)
        let fm = FileManager.default
        let original = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var dict: [String: Any] = [:]
        if let original = original {
            guard let parsed = try PropertyListSerialization.propertyList(
                from: original, format: nil) as? [String: Any] else {
                throw NSError(domain: "MacRemote Display Modes", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Existing display override cannot be parsed."])
            }
            dict = parsed
        }
        // Keep all original metadata (especially EDID and all existing mode variants).
        if let v = dict["DisplayVendorID"] as? Int, v != vendor {
            throw NSError(domain: "MacRemote Display Modes", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Existing display override vendor does not match."])
        }
        if let p = dict["DisplayProductID"] as? Int, p != product {
            throw NSError(domain: "MacRemote Display Modes", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Existing display override product does not match."])
        }
        dict["DisplayVendorID"] = vendor
        dict["DisplayProductID"] = product
        guard dict["scale-resolutions"] == nil || dict["scale-resolutions"] is [Data] else {
            throw NSError(domain: "MacRemote Display Modes", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Existing display mode list is unsupported; refusing to overwrite."])
        }
        var entries = dict["scale-resolutions"] as? [Data] ?? []
        var missing: [String] = []
        for (w, h) in sizes {
            // The connected display's existing override represents explicit
            // HiDPI entries as 16-byte big-endian records:
            // (2x width, 2x height, 9, 0x00200000).
            // The previous installer wrote only the first eight bytes; keep
            // those existing records and complete the HiDPI variant.
            func record(_ words: [UInt32]) -> Data {
                var data = Data()
                for word in words {
                    var networkOrder = word.bigEndian
                    data.append(Data(bytes: &networkOrder, count: 4))
                }
                return data
            }
            let base = [UInt32(w * 2), UInt32(h * 2)]
            let basic = record(base)
            let hiDPI = record(base + [9, 0x0020_0000])
            var added = false
            if !entries.contains(basic) {
                entries.append(basic)
                added = true
            }
            if !entries.contains(hiDPI) {
                entries.append(hiDPI)
                added = true
            }
            if added { missing.append("\(w)x\(h)") }
        }
        print("Display: \(suffix)")
        print("New 2x HiDPI definitions: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
        if operation == "plan" { return }
        guard geteuid() == 0 else {
            throw NSError(domain: "MacRemote Display Modes", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Administrator authorization is required."])
        }
        guard !missing.isEmpty else { return }
        dict["scale-resolutions"] = entries
        let result = try PropertyListSerialization.data(fromPropertyList: dict,
                                                     format: .xml, options: 0)
        let backupFolder = URL(fileURLWithPath: "/Library/Application Support/MacRemote/DisplayOverrideBackups")
        try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        if let original = original {
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let filename = suffix.replacingOccurrences(of: "/", with: "-") + "-" + timestamp + ".plist"
            let backup = backupFolder.appendingPathComponent(filename)
            try original.write(to: backup, options: .atomic)
            _ = chmod(backup.path, 0o600)
            print("Backup: \(backup.path)")
        }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.write(to: file, options: .atomic)
        _ = chmod(file.path, 0o644)
        print("Installed. Restart macOS to activate new modes.")
    }
}

@main
struct DisplayOverrideTool {
    static func main() {
        do {
            try DisplayOverrideInstaller.main()
        } catch {
            fputs("Display modes: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
