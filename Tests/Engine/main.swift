import Darwin
import Foundation

func engineExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw EngineFailure("test", message) }
}

Task { @MainActor in
    do {
        try await runJavaScriptTests()
        try await runTransportTests()
        try await runRuntimeTests()
        try await runMCPTests()
        print("Native engine tests passed")
        exit(0)
    } catch {
        let message = (error as? EngineFailure)?.message ?? "Native engine test failed"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
RunLoop.main.run()
