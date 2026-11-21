import AppKit

@main
struct MacRemoteApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MacRemoteDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
