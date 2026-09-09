import Darwin
import Foundation

#if !PASSTRAMI_MCP_TEST
@main
enum PasstramiMCP {
    static func main() async {
        guard CommandLine.arguments.count == 1 else {
            try? FileHandle.standardError.write(contentsOf: Data("passtrami-mcp takes no arguments. Configure it as a stdio MCP server.\n".utf8))
            Darwin.exit(64)
        }
        do { try await CredentialServer.run(backend: EngineBackend()) }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("Passtrami MCP stopped because the connection failed.\n".utf8))
            Darwin.exit(1)
        }
    }
}
#endif
