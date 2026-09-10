import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if let status = TouchIDPreferenceWindow.runGuardIfRequested(arguments) { exit(status) }
guard arguments.count == 4, arguments[0] == "--resources", arguments[2] == "--data-dir" else {
    FileHandle.standardError.write(Data("Usage: passtrami-engine --resources <path> --data-dir <path>\n".utf8))
    exit(64)
}
let engine = JavaScriptEngine(resources: URL(fileURLWithPath: arguments[1], isDirectory: true),
                              dataDirectory: URL(fileURLWithPath: arguments[3], isDirectory: true))
Task { @MainActor in
    do { try await engine.start() }
    catch {
        let message = (error as? EngineFailure)?.message ?? "Could not start the password service."
        if var data = try? JSONSerialization.data(withJSONObject: ["type": "state", "state": "error", "message": message]) {
            data.append(0x0A)
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        exit(1)
    }
}
RunLoop.main.run()
