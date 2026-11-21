import Foundation

/// Single source of truth for MacRemote's two bandwidth modes on the macOS app side.
/// Mirrors src/stream/stream_profile.c. New devices default to `.high` (LAN).
enum BandwidthMode: String, CaseIterable, Identifiable {
    case high
    case low

    var id: Self { self }

    var shortLabel: String {
        switch self {
        case .high: "High · LAN"
        case .low: "Low · ≤200 KB/s"
        }
    }

    var summary: String {
        switch self {
        case .high: "60 fps · up to 100 Mbps · lossless PCM audio"
        case .low: "15 fps · ≤200 KB/s cap · 48–64 kbps audio"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "bandwidthMode") ?? "") ?? .high
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "bandwidthMode")
    }
}
