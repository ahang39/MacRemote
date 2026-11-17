import Foundation

struct DisplaySize: Hashable, Codable, Comparable {
    let width: Int
    let height: Int

    var label: String { "\(width) × \(height)" }
    var isSixteenNine: Bool { width * 9 == height * 16 }
    var isValid: Bool {
        width >= 800 && width <= 8192 && height >= 450 && height <= 4320 &&
            width % 2 == 0 && height % 2 == 0 && isSixteenNine
    }

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    init?(text: String) {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        self.init(w, h)
        guard isValid else { return nil }
    }

    static func < (lhs: DisplaySize, rhs: DisplaySize) -> Bool {
        lhs.width == rhs.width ? lhs.height < rhs.height : lhs.width < rhs.width
    }
}

enum DisplayScalePlan {
    // Deliberately non-linear: fine adjustment around 100%, broader at high scale.
    static let percentages = [100, 105, 110, 120, 135, 150, 175, 200]
    static let previousPercentages = [100, 125, 150, 175, 200]
    static let reuseTolerances = [0, 1, 3, 5]
    static let defaultReuseTolerance = 3
    // Existing 2x display modes may be a pixel or two away from an exact ratio.
    static let maximumAspectError = 0.005

    static func nearestStep(to percent: Int) -> Int {
        nearestStep(to: Double(percent))
    }

    static func nearestStep(to percent: Double) -> Int {
        percentages.indices.min {
            let first = abs(Double(percentages[$0]) - percent)
            let second = abs(Double(percentages[$1]) - percent)
            return abs(first - second) > 1e-9 ? first < second : $0 < $1
        } ?? 0
    }

    static func modes(base: DisplaySize) -> [DisplaySize] {
        percentages.map { percent in
            let n = max(1, Int((Double(base.width) * 100 / (32 * Double(percent))).rounded()))
            return DisplaySize(n * 32, n * 18)
        }
    }

    static func percentage(base: DisplaySize, mode: DisplaySize) -> Int {
        Int((100.0 * Double(base.width) / Double(mode.width)).rounded())
    }

    static func effectivePercentage(base: DisplaySize, mode: DisplaySize) -> Double {
        100.0 * Double(base.width) / Double(mode.width)
    }

    // Kept separate from DisplaySize.isValid: RDP output must be exactly even
    // 16:9, but a system-provided Retina mode may round to odd logical pixels.
    static func isCompatibleExisting(_ mode: DisplaySize, base: DisplaySize) -> Bool {
        guard mode.width >= 800, mode.width <= 8192,
              mode.height >= 450, mode.height <= 4320 else { return false }
        let ratio = Double(mode.width) / Double(mode.height)
        let expected = Double(base.width) / Double(base.height)
        return abs(ratio / expected - 1) <= maximumAspectError
    }

    // Compare both dimensions to the *unrounded* ideal target. A candidate
    // must fall in the selected nominal step's Voronoi band, so a 105% option
    // cannot quietly reuse the 100% mode merely because tolerance is 5%.
    static func resolution(base: DisplaySize, step: Int,
                           existing: Set<DisplaySize>, tolerance: Int) -> DisplayScaleResolution? {
        guard base.isValid, percentages.indices.contains(step),
              reuseTolerances.contains(tolerance) else { return nil }
        let nominal = modes(base: base)[step]
        guard nominal.isValid else { return nil }
        let requested = Double(percentages[step])
        let idealWidth = Double(base.width) * 100 / requested
        let idealHeight = Double(base.height) * 100 / requested

        let matches = existing.filter { candidate in
            guard isCompatibleExisting(candidate, base: base) else { return false }
            let error = max(abs(idealWidth / Double(candidate.width) - 1),
                            abs(idealHeight / Double(candidate.height) - 1))
            guard error <= Double(tolerance) / 100 + 1e-9 else { return false }
            let actual = effectivePercentage(base: base, mode: candidate)
            return nearestStep(to: actual) == step
        }
        // The generated nominal mode wins when already supported; otherwise
        // use minimum relative geometric error and deterministic tie-breakers.
        let chosen: DisplaySize
        if existing.contains(nominal) {
            chosen = nominal
        } else {
            chosen = matches.min {
                let error0 = max(abs(idealWidth / Double($0.width) - 1),
                                 abs(idealHeight / Double($0.height) - 1))
                let error1 = max(abs(idealWidth / Double($1.width) - 1),
                                 abs(idealHeight / Double($1.height) - 1))
                if abs(error0 - error1) > 1e-9 { return error0 < error1 }
                if $0.width != $1.width { return $0.width < $1.width }
                return $0.height < $1.height
            } ?? nominal
        }
        return DisplayScaleResolution(nominal: nominal, selected: chosen,
                                      existing: existing.contains(chosen),
                                      actualPercent: effectivePercentage(base: base, mode: chosen))
    }
}

struct DisplayScaleResolution: Equatable {
    let nominal: DisplaySize
    let selected: DisplaySize
    let existing: Bool
    let actualPercent: Double

    var isReused: Bool { existing && selected != nominal }
}

enum DisplayModeDefinitions {
    // The existing AOC / BetterDisplay override uses 16-byte records for
    // explicit HiDPI modes: 2x backing width/height plus 9 and 0x00200000.
    // The first eight bytes alone only establish a basic scaled resolution.
    static func backingBytes(_ mode: DisplaySize) -> Data {
        let values: [UInt32] = [
            UInt32(mode.width * 2), UInt32(mode.height * 2), 9, 0x0020_0000
        ]
        var result = Data()
        for number in values {
            var bigEndian = number.bigEndian
            result.append(Data(bytes: &bigEndian, count: 4))
        }
        return result
    }

    static func contains(_ mode: DisplaySize, entries: [Data]) -> Bool {
        let fullRecord = backingBytes(mode)
        return entries.contains(fullRecord)
    }
}

enum DisplayChoiceAction: Equatable {
    case invalid, install, restartRequired, unsupported, apply, applied

    static func next(target: DisplaySize?, supported: Set<DisplaySize>,
                     configured: Set<DisplaySize>, selectionChanged: Bool,
                     modeApplied: Bool, overrideUpdatedSinceBoot: Bool = true) -> Self {
        guard let target else { return .invalid }
        if !supported.contains(target) {
            guard configured.contains(target) else { return .install }
            // SLSDetectDisplays does not reload a newly written display override.
            // After a reboot, a still-hidden mode may be unsupported by macOS.
            return overrideUpdatedSinceBoot ? .restartRequired : .unsupported
        }
        return selectionChanged || !modeApplied ? .apply : .applied
    }
}
