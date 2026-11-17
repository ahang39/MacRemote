import Foundation

enum DisplayModeOperations {
    static func install(_ sizes: [DisplaySize]) throws {
        let helper = executable("macremote-display-overrides")
        let command = ([helper.path, "install"] + sizes.map { "\($0.width)x\($0.height)" })
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        )
    }

    private static func executable(_ name: String) -> URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func run(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: output, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "MacRemote.DisplayModeOperations",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: details]
            )
        }
    }
}
