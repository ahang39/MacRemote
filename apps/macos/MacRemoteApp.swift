import AppKit
import CoreGraphics
import Foundation
import SwiftUI

private struct Readiness: Decodable {
    let account: String
    let screen_capture_granted: Bool
}

final class MacRemoteController: ObservableObject {
    static let shared = MacRemoteController()

    @Published var account = NSUserName()
    @Published var screenCaptureGranted = false
    @Published var isRunning = false
    @Published var port = ListenPortSettings.load() {
        didSet { ListenPortSettings.save(port) }
    }
    @Published var statusText = "Checking..."
    @Published var errorText: String?

    private var server: Process?
    private var logFile: FileHandle?
    private var wantsServer = false
    private var restartedAfterFailure = false
    private let executable = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/macremote-server")

    private func run(_ args: [String]) throws -> Data {
        let task = Process()
        task.executableURL = executable
        task.arguments = args
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        task.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if task.terminationStatus != 0 {
            let details = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Unknown error"
            throw NSError(domain: "MacRemote", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: details])
        }
        return data
    }

    func refresh() {
        do {
            let info = try JSONDecoder().decode(
                Readiness.self, from: run(["status", "--json"])
            )
            account = info.account
            // Check both the UI process and the real capture helper: TCC may
            // attribute permissions differently when a helper is spawned.
            screenCaptureGranted = CGPreflightScreenCaptureAccess()
                && info.screen_capture_granted
            if !isRunning {
                statusText = screenCaptureGranted
                    ? "Ready · Mac account login"
                    : "Screen Recording permission needed"
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            statusText = "Unavailable"
        }
    }

    func start() {
        guard server == nil else { return }
        wantsServer = true
        restartedAfterFailure = false
        launchServer()
    }

    private func launchServer() {
        refresh()
        guard screenCaptureGranted else {
            wantsServer = false
            errorText = "macOS has not granted MacRemote screen recording. "
                + "Choose Enable Screen Recording, allow MacRemote in System Settings, "
                + "then quit and reopen MacRemote before starting the server."
            return
        }
        guard let number = UInt16(port), number > 0 else {
            wantsServer = false
            errorText = "Port must be between 1 and 65535."
            return
        }
        let task = Process()
        task.executableURL = executable
        // Classic is the only graphics path validated with Windows mstsc.
        task.arguments = ["serve", "--port", String(number), "--gfx", "classic"]
        do {
            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MacRemote", isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let logURL = folder.appendingPathComponent("server.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                _ = FileManager.default.createFile(
                    atPath: logURL.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            logFile = handle
            task.standardOutput = handle
            task.standardError = handle
            task.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    self?.serverDidExit(process)
                }
            }
            try task.run()
            server = task
            isRunning = true
            statusText = "Running · TCP \(number)"
            errorText = nil
        } catch {
            wantsServer = false
            try? logFile?.close()
            logFile = nil
            statusText = "Start failed"
            errorText = error.localizedDescription
        }
    }

    private func serverDidExit(_ process: Process) {
        guard server === process else { return }
        server = nil
        isRunning = false
        try? logFile?.close()
        logFile = nil

        if wantsServer && !restartedAfterFailure {
            restartedAfterFailure = true
            statusText = "Restarting server..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, self.wantsServer else { return }
                self.launchServer()
            }
            return
        }

        statusText = "Stopped"
        if wantsServer {
            errorText = "Server exited with status \(process.terminationStatus). See server log."
        }
        wantsServer = false
    }

    func stop() {
        wantsServer = false
        if let server = server, server.isRunning {
            server.terminate()
            statusText = "Stopping..."
        } else {
            statusText = "Stopped"
        }
    }

    func requestScreenCapturePermission() {
        // Trigger Apple's normal, user-consent-controlled TCC prompt from the
        // actual MacRemote GUI, instead of launching a failing RDP listener.
        _ = CGRequestScreenCaptureAccess()
        refresh()
        if !screenCaptureGranted {
            errorText = "Allow MacRemote in Privacy & Security → Screen & "
                + "System Audio Recording. macOS may require restarting the app."
            openPermissions()
        }
    }

    func openPermissions() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// The registered app directly owns a normal NSStatusItem, just like USB
// Volume and Virtual Mic. Clicking the icon opens full SwiftUI settings.
final class MacRemoteDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var settingsPopover: NSPopover?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "desktopcomputer",
                accessibilityDescription: "MacRemote"
            )
            button.image?.isTemplate = true
            button.toolTip = "MacRemote settings"
            button.target = self
            button.action = #selector(toggleSettingsPopover)
        }
        statusItem = item
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MacRemoteController.shared.refresh()
        }
        // Drop graphics presets and icon preferences from earlier previews:
        // the server now always uses the validated Classic profile.
        for key in ["graphicsMode", "compatibilityGraphics", "showMenuBarIcon"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        MacRemoteController.shared.refresh()
        // Used only for a controlled in-place application update: relaunch
        // the existing native server with the same saved graphics/port settings.
        if ProcessInfo.processInfo.arguments.contains("--start-server") {
            DispatchQueue.main.async {
                MacRemoteController.shared.start()
            }
        }
    }

    @objc private func toggleSettingsPopover() {
        if settingsPopover?.isShown == true {
            settingsPopover?.performClose(nil)
        } else {
            showSettingsPopover()
        }
    }

    private func showSettingsPopover() {
        guard let button = statusItem?.button else { return }
        if settingsPopover?.isShown == true { return }

        MacRemoteController.shared.refresh()
        if settingsPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            let hosting = NSHostingController(rootView: MacRemoteMenu())
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
            settingsPopover = popover
        }
        settingsPopover?.show(
            relativeTo: button.bounds, of: button, preferredEdge: .minY
        )
        monitorOutsideClicks()
    }

    private func monitorOutsideClicks() {
        removeOutsideClickMonitors()
        let clicks: NSEvent.EventTypeMask =
            [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // NSPopover.transient handles standard focus changes. A menu bar
        // accessory app can remain inactive while the user clicks in a
        // different app; explicitly close in that situation as well.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) {
            [weak self] _ in
            self?.settingsPopover?.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) {
            [weak self] event in
            guard let self = self, self.settingsPopover?.isShown == true else {
                return event
            }
            let popoverWindow = self.settingsPopover?.contentViewController?.view.window
            let statusWindow = self.statusItem?.button?.window
            if event.window !== popoverWindow && event.window !== statusWindow {
                self.settingsPopover?.performClose(nil)
            }
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        // Finder/Spotlight and the menu bar icon use the same dismissible UI.
        showSettingsPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeOutsideClickMonitors()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        MacRemoteController.shared.stop()
    }
}

struct MacRemoteMenu: View {
    @ObservedObject private var controller = MacRemoteController.shared
    private let accent = Color(red: 0.831, green: 0.529, blue: 0.322)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 24))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacRemote")
                        .font(.system(.headline, design: .rounded))
                    Text(controller.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(controller.isRunning ? .green : .gray)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }

            Divider()
            HStack {
                Label("Mac login", systemImage: "person.crop.circle")
                Spacer()
                Text(controller.account)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack {
                Label("Authentication", systemImage: "lock")
                Spacer()
                Text("TLS + Mac password")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            HStack {
                Label("Listen port", systemImage: "network")
                Spacer()
                TextField("Port", text: $controller.port)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("RDP listen port")
                    .accessibilityHint("Set the TCP port while the server is stopped")
                    .disabled(controller.isRunning)
            }
            .font(.callout)

            HStack {
                Label("Screen recording", systemImage: "rectangle.on.rectangle")
                Spacer()
                Text(controller.screenCaptureGranted ? "Granted" : "Permission needed")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            if let error = controller.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()

            Button {
                if controller.isRunning { controller.stop() }
                else { controller.start() }
            } label: {
                Label(
                    controller.isRunning ? "Stop RDP server" : "Start RDP server",
                    systemImage: controller.isRunning ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)

            HStack {
                Button("Refresh") { controller.refresh() }
                if !controller.screenCaptureGranted {
                    Button("Enable Screen Recording") {
                        controller.requestScreenCapturePermission()
                    }
                }
                Spacer()
                Button("Quit") {
                    controller.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .frame(width: 335)
        .padding(16)
        .onAppear { controller.refresh() }
    }
}

@main
struct MacRemoteApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MacRemoteDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
