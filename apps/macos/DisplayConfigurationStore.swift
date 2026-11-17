import Foundation

struct DisplayConfigurationStore {
    let directory: URL
    let defaults: UserDefaults

    private let scaleKey = "rdpScaleStep"
    private let scalePercentKey = "rdpScalePercent"
    private let legacyOutputKey = "rdpOutputSize"

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacRemote"),
        defaults: UserDefaults = .standard
    ) {
        self.directory = directory
        self.defaults = defaults
    }

    var outputURL: URL { directory.appendingPathComponent("display-output.conf") }
    var captureLogicalURL: URL { directory.appendingPathComponent("capture-logical.conf") }

    func runningOutput() -> DisplaySize? {
        guard let content = try? String(contentsOf: outputURL, encoding: .utf8) else {
            return nil
        }
        let parts = content.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            return nil
        }
        let size = DisplaySize(width, height)
        return size.isValid ? size : nil
    }

    func initialOutput() -> DisplaySize {
        runningOutput()
            ?? defaults.string(forKey: legacyOutputKey).flatMap(DisplaySize.init(text:))
            ?? DisplaySize(2304, 1296)
    }

    func initialScaleStep() -> Int {
        if let percent = defaults.object(forKey: scalePercentKey) as? Int {
            return DisplayScalePlan.nearestStep(to: percent)
        }
        let oldStep = min(4, max(0, defaults.integer(forKey: scaleKey)))
        return DisplayScalePlan.nearestStep(to: DisplayScalePlan.previousPercentages[oldStep])
    }

    func save(output: DisplaySize, scaleStep: Int) throws {
        precondition(output.isValid)
        precondition(DisplayScalePlan.percentages.indices.contains(scaleStep))
        try writePrivate(
            Data("\(output.width) \(output.height)\n".utf8), to: outputURL)
        defaults.set(DisplayScalePlan.percentages[scaleStep], forKey: scalePercentKey)
        defaults.removeObject(forKey: "rdpReuseTolerancePercent") // obsolete visible setting
        defaults.removeObject(forKey: scaleKey)
        defaults.removeObject(forKey: legacyOutputKey)
    }

    func saveCaptureGeometry(displayID: UInt32, width: Int, height: Int) throws {
        try writePrivate(Data("\(displayID) \(width) \(height)\n".utf8),
                         to: captureLogicalURL)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
