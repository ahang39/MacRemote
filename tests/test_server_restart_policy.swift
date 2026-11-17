import Foundation

@main
struct TestServerRestartPolicy {
    @MainActor
    static func main() async throws {
        let expected = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 60.0, 60.0]
        for (index, delay) in expected.enumerated() {
            precondition(ServerRestartPolicy.delay(forAttempt: index + 1) == delay)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("fake-server")
        let controller = MacRemoteController(executable: helper, logDirectory: folder)

        controller.start()
        precondition(!controller.wantsServer && controller.screenCaptureGranted == nil)
        precondition(controller.statusText == "Unavailable" && controller.errorText != nil)

        try """
        #!/bin/sh
        if [ "$1" = status ]; then
            printf '%s\\n' '{"account":"test","screen_capture_granted":true}'
            exit 0
        fi
        echo fake-server-started
        exit 17
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        controller.start()
        try await waitUntil { controller.statusText.hasPrefix("RDP recovery") }
        controller.refresh()
        precondition(controller.errorText?.contains("exit 17") == true)
        controller.stop()
        try await Task.sleep(for: .seconds(1.2))
        precondition(!controller.wantsServer)
        let log = try String(contentsOf: folder.appendingPathComponent("server.log"), encoding: .utf8)
        precondition(log.components(separatedBy: "fake-server-started").count == 2)
        print("PASS: helper failure, bounded recovery policy and cancellation on Stop")
    }

    @MainActor
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            precondition(ContinuousClock.now < deadline, "Timed out waiting for recovery")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
