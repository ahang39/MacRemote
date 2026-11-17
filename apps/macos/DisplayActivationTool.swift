import Foundation
import Darwin

// A one-shot, user-triggered macOS display detection pass.
// Runs in a separate process so a display reprobe cannot stall the menu bar.
@main
struct DisplayActivationTool {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args == ["check"] || args == ["activate"] else {
            fputs("Usage: macremote-display-activate check|activate\n", stderr)
            exit(2)
        }
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW) else {
            fputs("SkyLight is unavailable on this macOS version.\n", stderr)
            exit(3)
        }
        defer { dlclose(handle) }
        guard let address = dlsym(handle, "SLSDetectDisplays") else {
            fputs("Display detection is unsupported on this macOS version.\n", stderr)
            exit(3)
        }
        if args == ["check"] {
            print("SLSDetectDisplays available")
            return
        }
        typealias Detect = @convention(c) () -> Int32
        let detect = unsafeBitCast(address, to: Detect.self)
        let result = detect()
        guard result == 0 else {
            fputs("Display detection returned status \(result).\n", stderr)
            exit(4)
        }
        print("Display detection requested. Verify that modes have been loaded.")
    }
}
