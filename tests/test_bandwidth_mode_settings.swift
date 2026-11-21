import Foundation

@main
struct BandwidthModeSettingsTests {
    static func main() {
        let suite = "dev.macremote.bandwidth-mode-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        precondition(BandwidthMode.load(from: defaults) == .high)

        BandwidthMode.low.save(to: defaults)
        precondition(BandwidthMode.load(from: defaults) == .low)

        BandwidthMode.high.save(to: defaults)
        precondition(BandwidthMode.load(from: defaults) == .high)

        defaults.set("invalid", forKey: "bandwidthMode")
        precondition(BandwidthMode.load(from: defaults) == .high)

        print("PASS: BandwidthMode persistence defaults to High and validates stored values")
    }
}
