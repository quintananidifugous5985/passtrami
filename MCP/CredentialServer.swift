import Darwin
import Foundation
import MCP

enum CredentialServer {
    static let resourceURI = "passtrami://docs/credential-access"
    static let instructions = """
    Read passtrami://docs/credential-access before using credentials. This server returns account names and
    one-use pipe metadata, never passwords. Prepare the consumer first, then call prepare_password and
    immediately run that consumer. Read the pipe only inside the consuming process; never print, log,
    inspect, encode, or return its contents through any agent tool. Do not use passtrami get, cat, shell
    substitution, or a file-reading tool to obtain a password. Passwords must remain outside model
    messages and session transcripts. Use only the user-authorized website and account. The user
    completes unlock and system approval in Passtrami. Revoke unused leases with revoke_password.
    """

    static let guide = """
    # Credential access

    This local MCP server controls Passtrami. It does not return password values. Enable MCP in Passtrami
    Settings before calling credential tools. The app starts when needed. The user completes any
    unlock or system approval in Passtrami; do not request a PIN or password through MCP.

    ## Complete flow
    1. Call status. If enabled is false, ask the user to enable MCP in Passtrami Settings.
    2. Use list_accounts with the intended domain to choose the exact account. Account names are
       metadata and may appear in the transcript. Stay within the user's requested site and account.
    3. Prepare the application code that will use the password. It must accept a pipe path, read its
       bytes internally, send the password only to the intended service, and return a nonsecret result.
       Do this before requesting the password because the lease lasts only 60 seconds.
    4. Call prepare_password with domain and username. Wait for the user to finish authentication.
       The result contains lease_id, path, expires_at, format="utf8", and single_use=true.
    5. Immediately run the consumer with path as an ordinary argument. The path is safe metadata.
       The consumer opens the pipe and reads all bytes until EOF. These are the exact UTF-8 password
       bytes, with no added newline. Do not trim them. Empty bytes mean access was revoked or failed;
       stop without calling the service. Do not use a dotenv parser for this pipe.
    6. Use the password inside that process and return only a result such as "Login succeeded".
       Keep it out of stdout, stderr, exception text, debug logs, request logs, screenshots, command
       arguments, saved files, tool responses, and model messages. Do not return it encoded or hashed.
    7. If you do not use the pipe, call revoke_password with lease_id. After consumption, expiry,
       locking, disabling MCP, or closing this MCP connection, request a new lease when needed.

    ## Consumer example
    Prepare a script for the user's actual service. The following shows the local read boundary;
    replace the service call with the existing trusted client and avoid logging request contents.

    ```python
    import sys
    from my_service import sign_in

    try:
        with open(sys.argv[1], "rb") as pipe:
            password = pipe.read().decode("utf-8")
        if not password:
            raise ValueError("Password access ended")
        sign_in(username=sys.argv[2], password=password)
        del password
    except Exception:
        print("Login failed", file=sys.stderr)
        raise SystemExit(1) from None
    print("Login succeeded")
    ```

    The agent can run `python3 login.py <returned-path> <username>`. Do not run `cat`, a file reader,
    `passtrami get`, or shell substitution on the pipe. Do not put password bytes into an MCP resource.
    A failed, expired, or interrupted read needs a new prepare_password call.

    ## Limits
    Passwords longer than 512 UTF-8 bytes are rejected so delivery is one atomic pipe write.
    The pipe is local and readable by the current user. This design keeps passwords out of normal
    MCP responses and transcripts when the consumer follows these rules. It does not isolate a secret
    from arbitrary commands or other processes running as the same user. Access to an authenticated
    service must still be limited to the user's requested action.
    """

    static func make(backend: EngineBackend) async -> Server {
        let server = Server(name: "passtrami", version: "1.0.0", instructions: instructions,
                            capabilities: .init(resources: .init(), tools: .init()), configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [.init(name: "Credential access", uri: resourceURI,
                                   description: "Full workflow for using a password without returning it to the agent.",
                                   mimeType: "text/markdown")])
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard params.uri == resourceURI else { throw MCPError.invalidParams("Unknown resource.") }
            return .init(contents: [.text(guide, uri: resourceURI, mimeType: "text/markdown")])
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let values = try await call(params, backend: backend)
                let data = try JSONEncoder().encode(Value.object(values))
                return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                             structuredContent: .object(values), isError: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MCPError {
                throw error
            } catch {
                let message = (error as? CredentialAccessError)?.message ?? CredentialAccessError.failed.message
                return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
            }
        }
        return server
    }

    static func run(backend: EngineBackend) async throws {
        let server = await make(backend: backend)
        signal(SIGPIPE, SIG_IGN)
        let signals = [SIGINT, SIGTERM, SIGHUP].map { signalNumber -> any DispatchSourceSignal in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                Task {
                    await backend.close()
                    await server.stop()
                }
            }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        do {
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            await backend.close()
            await server.stop()
            throw error
        }
        await backend.close()
        await server.stop()
    }

    private static func schema(_ properties: [String: Value]) -> Value {
        .object(["type": "object", "properties": .object(properties),
                 "required": .array(properties.keys.sorted().map(Value.string)), "additionalProperties": false])
    }

    static let tools: [Tool] = [
        .init(name: "status", description: "Check whether MCP is enabled and whether Passtrami is locked. No password access.",
              inputSchema: schema([:]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        .init(name: "list_accounts", description: "List usernames saved for a domain. Waits for user authentication if needed. Returns names only.",
              inputSchema: schema(["domain": ["type": "string", "minLength": 1]]),
              annotations: .init(readOnlyHint: true, openWorldHint: false)),
        .init(name: "prepare_password", description: "After user authentication, prepare a one-use UTF-8 password pipe for an exact domain and username. Read credential-access documentation first. Returns metadata only; the consumer must read the pipe internally within 60 seconds without printing it.",
              inputSchema: schema(["domain": ["type": "string", "minLength": 1],
                                   "username": ["type": "string", "minLength": 1]]),
              annotations: .init(destructiveHint: false, openWorldHint: false)),
        .init(name: "revoke_password", description: "Remove an unused password pipe created by this MCP connection.",
              inputSchema: schema(["lease_id": ["type": "string", "format": "uuid"]]),
              annotations: .init(destructiveHint: true, idempotentHint: true, openWorldHint: false))
    ]

    private static func arguments(_ params: CallTool.Parameters, keys: Set<String>) throws -> [String: String] {
        let arguments = params.arguments ?? [:]
        guard Set(arguments.keys) == keys else { throw MCPError.invalidParams("Use exactly the documented tool arguments.") }
        var result: [String: String] = [:]
        for key in keys {
            guard let value = arguments[key]?.stringValue,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 1_024, !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw MCPError.invalidParams("Tool arguments must be nonempty strings without line breaks.")
            }
            result[key] = value
        }
        return result
    }

    private static func call(_ params: CallTool.Parameters, backend: EngineBackend) async throws -> [String: Value] {
        switch params.name {
        case "status":
            _ = try arguments(params, keys: [])
            let response = try await backend.request("mcp_status")
            guard let enabled = response.enabled, let state = response.state,
                  ["starting", "locked", "pairing", "unlocked", "error"].contains(state) else {
                throw CredentialAccessError.invalidResponse
            }
            return ["enabled": .bool(enabled), "state": .string(state)]
        case "list_accounts":
            let arguments = try arguments(params, keys: ["domain"])
            let response = try await backend.request("mcp_list", arguments: arguments)
            guard let usernames = response.usernames,
                  usernames.allSatisfy({ !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else {
                throw CredentialAccessError.invalidResponse
            }
            return ["usernames": .array(usernames.map(Value.string))]
        case "prepare_password":
            let arguments = try arguments(params, keys: ["domain", "username"])
            let response = try await backend.request("mcp_prepare", arguments: arguments)
            guard let id = response.lease_id, UUID(uuidString: id) != nil,
                  let path = response.path, path.hasPrefix("/"), path.utf8.count <= 1_024,
                  !path.contains(where: { $0.isNewline || $0 == "\0" }),
                  let expiration = response.expires_at, ISO8601DateFormatter().date(from: expiration) != nil,
                  response.format == "utf8", response.single_use == true else {
                throw CredentialAccessError.invalidResponse
            }
            return ["lease_id": .string(id), "path": .string(path), "expires_at": .string(expiration),
                    "format": "utf8", "single_use": true]
        case "revoke_password":
            let arguments = try arguments(params, keys: ["lease_id"])
            guard UUID(uuidString: arguments["lease_id"]!) != nil else { throw MCPError.invalidParams("lease_id must be a UUID.") }
            _ = try await backend.request("mcp_revoke", arguments: arguments)
            return ["revoked": true]
        default:
            throw MCPError.invalidParams("Unknown tool.")
        }
    }
}
