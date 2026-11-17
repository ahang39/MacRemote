import CoreGraphics
import Foundation

struct ClientDevicePreferences {
    struct Audio: Equatable {
        let volume: Int
        let muted: Bool

        fileprivate init(fields: [String: Any]) {
            let number = fields["audioVolume"] as? NSNumber
            let value = number.flatMap {
                CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue
            } ?? 100
            volume = Int(min(100, max(0, value)))

            let mute = fields["audioMuted"] as? NSNumber
            muted = mute.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        }
    }

    enum VideoBitrate: Int, CaseIterable {
        case low = 1_400_000
        case medium = 2_000_000
        case high = 4_000_000

        var label: String {
            switch self {
            case .low: "1.4"
            case .medium: "2.0"
            case .high: "4.0"
            }
        }
    }

    struct ActiveClient: Equatable {
        let key: String
        let audio: Audio
        let bitrate: VideoBitrate

        fileprivate init(key: String, fields: [String: Any]) {
            self.key = key
            audio = Audio(fields: fields)
            bitrate = VideoBitrate.allCases.first {
                (fields["videoBitrate"] as? NSNumber) == NSNumber(value: $0.rawValue)
            } ?? .high
        }
    }

    enum Change {
        case volume(Int)
        case toggleMute
        case bitrate(VideoBitrate)
    }

    let directory: URL

    private var profileURL: URL { directory.appendingPathComponent("display-by-client.json") }

    private func clientKey(serverPID: Int32? = nil) -> String? {
        let url = directory.appendingPathComponent("rdp-active-client.key")
        guard let state = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = state.split(whereSeparator: \.isWhitespace)
        guard let key = parts.first, key.utf8.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        if let serverPID {
            guard parts.count == 2, Int32(parts[1]) == serverPID else { return nil }
        }
        return String(key)
    }

    func displayProfile(fallbackOutput: DisplaySize)
        -> (output: DisplaySize, mode: DisplaySize, nominalPercent: Int?)? {
        guard let key = clientKey(),
              let selected = (try? readProfiles())?[key] as? [String: Any],
              let logicalWidth = selected["logicalWidth"] as? NSNumber,
              let logicalHeight = selected["logicalHeight"] as? NSNumber else { return nil }
        let mode = DisplaySize(logicalWidth.intValue, logicalHeight.intValue)
        if let width = selected["rdpWidth"] as? NSNumber,
           let height = selected["rdpHeight"] as? NSNumber {
            let output = DisplaySize(width.intValue, height.intValue)
            return output.isValid
                ? (output, mode, (selected["uiScalePercent"] as? NSNumber)?.intValue)
                : nil
        }
        return (fallbackOutput, mode, (selected["uiScalePercent"] as? NSNumber)?.intValue)
    }

    func activeClient(serverPID: Int32?) -> ActiveClient? {
        guard let serverPID, let key = clientKey(serverPID: serverPID) else { return nil }
        let profiles = try? readProfiles()
        return ActiveClient(key: key, fields: Self.fields(for: key, in: profiles ?? [:]))
    }

    func update(_ change: Change, for key: String, serverPID: Int32) throws -> ActiveClient? {
        try updateProfiles { profiles in
            guard clientKey(serverPID: serverPID) == key else { return nil }
            var fields = Self.fields(for: key, in: profiles)
            switch change {
            case .volume(let value):
                fields["audioVolume"] = min(100, max(0, value))
            case .toggleMute:
                fields["audioMuted"] = !Audio(fields: fields).muted
            case .bitrate(let target):
                fields["videoBitrate"] = target.rawValue
            }
            profiles[key] = fields
            return ActiveClient(key: key, fields: fields)
        }
    }

    @discardableResult
    func saveDisplay(output: DisplaySize, mode: CGDisplayMode,
                     previousOutput: DisplaySize?, nominalPercent: Int? = nil) throws -> Bool {
        guard let key = clientKey() else { return false }
        return try updateProfiles { profiles in
            if let previousOutput {
                for (client, value) in profiles {
                    guard var legacy = value as? [String: Any],
                          legacy["logicalWidth"] != nil, legacy["rdpWidth"] == nil else { continue }
                    legacy["rdpWidth"] = previousOutput.width
                    legacy["rdpHeight"] = previousOutput.height
                    profiles[client] = legacy
                }
            }

            var fields = Self.fields(for: key, in: profiles)
            fields["rdpWidth"] = output.width
            fields["rdpHeight"] = output.height
            fields["logicalWidth"] = mode.width
            fields["logicalHeight"] = mode.height
            fields["renderWidth"] = mode.pixelWidth
            fields["renderHeight"] = mode.pixelHeight
            fields["refreshHz"] = mode.refreshRate
            if let nominalPercent { fields["uiScalePercent"] = nominalPercent }
            profiles[key] = fields
            return true
        } ?? false
    }

    private static func fields(for key: String, in profiles: [String: Any]) -> [String: Any] {
        profiles[key] as? [String: Any] ?? [:]
    }

    private func readProfiles() throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: profileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        guard let profiles = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return profiles
    }

    private func updateProfiles<Result>(
        _ edit: (inout [String: Any]) -> Result?
    ) throws -> Result? {
        let lockURL = directory.appendingPathComponent("display-by-client.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }

        var profiles = try readProfiles()
        guard let result = edit(&profiles) else { return nil }
        let data = try JSONSerialization.data(withJSONObject: profiles, options: [.sortedKeys])
        try data.write(to: profileURL, options: .atomic)
        guard chmod(profileURL.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return result
    }
}
