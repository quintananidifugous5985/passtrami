import Darwin
import Foundation

#if !ASTER_MCP_TEST
@main
enum AsterMCP {
    static func main() async {
        guard CommandLine.arguments.count == 1 else {
            try? FileHandle.standardError.write(contentsOf: Data("aster-mcp takes no arguments. Configure it as a stdio MCP server.\n".utf8))
            Darwin.exit(64)
        }
        do { try await CredentialServer.run(backend: EngineBackend()) }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("Aster MCP stopped because the connection failed.\n".utf8))
            Darwin.exit(1)
        }
    }
}
#endif
