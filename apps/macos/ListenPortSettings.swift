import Foundation

enum ListenPortSettings {
    static let defaultPort = "3389"
    private static let key = "listenPort"

    static func load(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key) ?? defaultPort
    }

    static func save(_ port: String, to defaults: UserDefaults = .standard) {
        guard let number = UInt16(port), number > 0 else { return }
        defaults.set(String(number), forKey: key)
    }
}
