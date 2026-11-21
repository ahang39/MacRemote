import AppKit
import CoreGraphics
import Combine
import Foundation

private struct ServerReadiness: Decodable {
    let account: String
    let screenCaptureGranted: Bool

    enum CodingKeys: String, CodingKey {
        case account
        case screenCaptureGranted = "screen_capture_granted"
    }
}

private enum ServerExit { case recover, restart, stop }

private enum ServerLifecycle {
    case stopped
    case running(Process, onExit: ServerExit)
    case recovering(DispatchWorkItem)

    var wantsServer: Bool {
        if case .stopped = self { return false }
        return true
    }

    var isRunning: Bool {
        if case .running(_, let onExit) = self { return onExit != .stop }
        return false
    }
}

@MainActor
final class MacRemoteController: ObservableObject {
    static let shared = MacRemoteController()

    @Published private var lifecycle: ServerLifecycle = .stopped
    @Published private(set) var account = NSUserName()
    @Published private(set) var screenCaptureGranted: Bool?
    @Published var port = ListenPortSettings.load() {
        didSet { ListenPortSettings.save(port) }
    }
    @Published var defaultBandwidthMode = BandwidthMode.load() {
        didSet { defaultBandwidthMode.save() }
    }
    @Published private(set) var statusText = "Checking..."
    @Published private var serverError: String?
    @Published private var readinessError: String?

    var errorText: String? { readinessError ?? serverError }

    var wantsServer: Bool { lifecycle.wantsServer }
    var isRunning: Bool { lifecycle.isRunning }
    var servingProcessID: Int32? {
        guard case .running(let process, .recover) = lifecycle, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private let executable: URL
    private let logDirectory: URL
    private var logFile: FileHandle?
    private var startedAt: TimeInterval = 0
    private var restartAttempts = 0

    init(executable: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/macremote-server"),
         logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacRemote", isDirectory: true)) {
        self.executable = executable
        self.logDirectory = logDirectory
    }

    private func runStatus() throws -> ServerReadiness {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MacRemote", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "The RDP helper status check exited with code \(process.terminationStatus)."])
        }
        return try JSONDecoder().decode(ServerReadiness.self, from: data)
    }

    private func checkReadiness() -> Bool {
        do {
            let readiness = try runStatus()
            account = readiness.account
            screenCaptureGranted = readiness.screenCaptureGranted
            readinessError = nil
            return true
        } catch {
            screenCaptureGranted = nil
            readinessError = "Could not check the RDP helper: \(error.localizedDescription)"
            return false
        }
    }

    func refresh() {
        let available = checkReadiness()
        guard !wantsServer, serverError == nil else { return }
        statusText = available
            ? (screenCaptureGranted == true ? "Stopped" : "Screen Recording needed")
            : "Unavailable"
    }

    func start() {
        guard case .stopped = lifecycle else { return }
        restartAttempts = 0
        launch()
    }

    private func launch() {
        serverError = nil
        guard checkReadiness() else {
            lifecycle = .stopped
            statusText = "Unavailable"
            return
        }
        guard screenCaptureGranted == true else {
            stopWithError("macOS has not granted MacRemote screen recording. "
                + "Choose Enable Screen Recording, allow MacRemote in System Settings, "
                + "then quit and reopen MacRemote before starting the server.")
            return
        }
        guard let number = UInt16(port), number > 0 else {
            stopWithError("Port must be between 1 and 65535.")
            return
        }

        let process = Process()
        process.executableURL = executable
        // --headless is a no-op while a physical or BetterDisplay screen is present.
        process.arguments = ["serve", "--port", String(number), "--bandwidth",
                             defaultBandwidthMode.rawValue, "--headless"]

        do {
            try FileManager.default.createDirectory(
                at: logDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let path = logDirectory.appendingPathComponent("server.log")
            if !FileManager.default.fileExists(atPath: path.path) {
                _ = FileManager.default.createFile(
                    atPath: path.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let log = try FileHandle(forWritingTo: path)
            _ = try log.seekToEnd()
            logFile = log
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] finished in
                DispatchQueue.main.async {
                    self?.serverDidExit(finished)
                }
            }
            try process.run()
            startedAt = ProcessInfo.processInfo.systemUptime
            lifecycle = .running(process, onExit: .recover)
            statusText = "Running · TCP \(number)"
        } catch {
            closeLog()
            stopWithError("Unable to start RDP: \(error.localizedDescription)")
        }
    }

    private func closeLog() {
        try? logFile?.close()
        logFile = nil
    }

    private func stopWithError(_ reason: String) {
        lifecycle = .stopped
        statusText = "Stopped"
        serverError = reason
    }

    private func recover(after reason: String) {
        if ProcessInfo.processInfo.systemUptime - startedAt >= 60 {
            restartAttempts = 0
        }
        guard restartAttempts < 5 else {
            stopWithError("RDP stopped after repeated failures. \(reason)")
            return
        }
        restartAttempts += 1
        let delay = ServerRestartPolicy.delay(forAttempt: restartAttempts)
        statusText = "RDP recovery in \(Int(delay))s"
        serverError = reason
        let item = DispatchWorkItem { [weak self] in self?.launch() }
        lifecycle = .recovering(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func serverDidExit(_ process: Process) {
        guard case .running(let current, let transition) = lifecycle,
              current === process else { return }

        let reason = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
        let detail = "RDP server \(reason) \(process.terminationStatus), pid \(process.processIdentifier)"
        try? logFile?.write(contentsOf: Data("[MacRemote GUI] \(Date()) \(detail)\n".utf8))
        closeLog()

        switch transition {
        case .stop:
            lifecycle = .stopped
            statusText = "Stopped"
            serverError = nil
        case .restart:
            restartAttempts = 0
            launch()
        case .recover:
            recover(after: detail)
        }
    }

    func restartForOutputChange() {
        guard case .running(let process, .recover) = lifecycle else { return }
        lifecycle = .running(process, onExit: .restart)
        statusText = "Restarting with new output…"
        terminate(process)
    }

    func stop() {
        switch lifecycle {
        case .stopped, .running(_, .stop):
            return
        case .running(let process, _):
            lifecycle = .running(process, onExit: .stop)
            statusText = "Stopping..."
            terminate(process)
        case .recovering(let item):
            item.cancel()
            lifecycle = .stopped
            statusText = "Stopped"
            serverError = nil
        }
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
        } else {
            serverDidExit(process)
        }
    }

    func requestScreenCapturePermission() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
        if screenCaptureGranted == false {
            readinessError = "Allow MacRemote in Privacy & Security → Screen & "
                + "System Audio Recording. macOS may require restarting the app."
            openPermissions()
        }
    }

    func openPermissions() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
