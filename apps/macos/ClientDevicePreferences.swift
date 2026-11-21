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

    struct SessionStatus: Equatable {
        let mode: BandwidthMode
        let codec: String?
        let colorDepth: Int?
        let videoBytesPerSec: Int
        let audioBytesPerSec: Int
        let fps: Int
        let ackRttMs: Int?
        let ackRttP95Ms: Int?
        let inFlightMax: Int

        var totalBytesPerSec: Int { videoBytesPerSec + audioBytesPerSec }
        var isLegacyColorDepth: Bool { (colorDepth ?? 32) < 32 }

        var formattedRate: String {
            let bytes = max(0, totalBytesPerSec)
            if bytes >= 1_000_000 {
                return String(format: "%.1f MB/s", Double(bytes) / 1_000_000.0)
            }
            return "\(Int((Double(bytes) / 1000.0).rounded())) KB/s"
        }
    }

    struct ActiveClient: Equatable {
        let key: String
        let audio: Audio
        let bandwidthMode: BandwidthMode

        fileprivate init(key: String, fields: [String: Any], fallbackMode: BandwidthMode = .high) {
            self.key = key
            audio = Audio(fields: fields)
            bandwidthMode = (fields["bandwidthMode"] as? String)
                .flatMap(BandwidthMode.init(rawValue:)) ?? fallbackMode
        }
    }

    enum Change {
        case volume(Int)
        case toggleMute
        case bandwidth(BandwidthMode)
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

    func activeClient(serverPID: Int32?, defaultMode: BandwidthMode = .high) -> ActiveClient? {
        guard let serverPID, let key = clientKey(serverPID: serverPID) else { return nil }
        let profiles = try? readProfiles()
        return ActiveClient(key: key,
                            fields: Self.fields(for: key, in: profiles ?? [:]),
                            fallbackMode: defaultMode)
    }

    func update(_ change: Change, for key: String, serverPID: Int32,
                defaultMode: BandwidthMode = .high) throws -> ActiveClient? {
        try updateProfiles { profiles in
            guard clientKey(serverPID: serverPID) == key else { return nil }
            var fields = Self.fields(for: key, in: profiles)
            switch change {
            case .volume(let value):
                fields["audioVolume"] = min(100, max(0, value))
            case .toggleMute:
                fields["audioMuted"] = !Audio(fields: fields).muted
            case .bandwidth(let mode):
                fields["bandwidthMode"] = mode.rawValue
            }
            profiles[key] = fields
            return ActiveClient(key: key, fields: fields, fallbackMode: defaultMode)
        }
    }

    func sessionStatus(serverPID: Int32?) -> SessionStatus? {
        guard let serverPID, let key = clientKey(serverPID: serverPID) else { return nil }
        let statusURL = directory.appendingPathComponent("rdp-session.json")
        guard let data = try? Data(contentsOf: statusURL),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["key"] as? String == key,
              (value["pid"] as? NSNumber)?.int32Value == serverPID,
              let modeName = value["mode"] as? String,
              let mode = BandwidthMode(rawValue: modeName) else { return nil }

        let codec = value["codec"] as? String
        let depth = (value["colorDepth"] as? NSNumber)?.intValue
        let video = max(0, (value["videoBytesPerSec"] as? NSNumber)?.intValue ?? 0)
        let audio = max(0, (value["audioBytesPerSec"] as? NSNumber)?.intValue ?? 0)
        let fps = max(0, (value["fps"] as? NSNumber)?.intValue ?? 0)
        let rtt = (value["ackRttMs"] as? NSNumber)?.intValue
        let rttP95 = (value["ackRttP95Ms"] as? NSNumber)?.intValue
        let inFlight = max(0, (value["inFlightMax"] as? NSNumber)?.intValue ?? 0)
        return SessionStatus(mode: mode,
                             codec: codec,
                             colorDepth: depth.flatMap { $0 > 0 ? $0 : nil },
                             videoBytesPerSec: video,
                             audioBytesPerSec: audio,
                             fps: fps,
                             ackRttMs: rtt,
                             ackRttP95Ms: rttP95,
                             inFlightMax: inFlight)
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
