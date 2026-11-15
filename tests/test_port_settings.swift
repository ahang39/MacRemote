import Foundation

@main
struct TestListenPortSettings {
    static func main() {
        let suite = "dev.macremote.port-tests.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        precondition(ListenPortSettings.load(from: defaults) == "3389")

        ListenPortSettings.save("3392", to: defaults)
        precondition(ListenPortSettings.load(from: defaults) == "3392")

        // A temporary invalid edit must not overwrite the last valid setting.
        ListenPortSettings.save("", to: defaults)
        ListenPortSettings.save("65536", to: defaults)
        precondition(ListenPortSettings.load(from: defaults) == "3392")

        ListenPortSettings.save("3389", to: defaults)
        precondition(ListenPortSettings.load(from: defaults) == "3389")
        print("PASS: default 3389, custom port persistence, invalid edits ignored")
    }
}
