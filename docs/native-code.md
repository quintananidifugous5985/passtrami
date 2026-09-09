# Native code

Start with these files. Paths below are relative to the project root.

| Read | Responsibility |
| --- | --- |
| `App/main.swift` → `App/AppDelegate.swift` | Start the menu app and connect menu actions, windows, and engine events. |
| `App/EngineProcess.swift` | Own the engine process. Send commands on stdin and receive events on stdout. |
| `CLI/main.swift` | Parse a command, open the app if needed, and send one request over its Unix socket. |
| `MCP/AsterMCP.swift` → `MCP/CredentialServer.swift` | Serve stdio MCP tools and agent instructions. Return metadata only. |
| `Shared/EngineConnection.swift` | Share the cancellable Unix socket connection and app launch code between CLI and MCP. |
| `EngineHost/main.swift` → `EngineHost/JavaScriptEngine.swift` | Start the engine and own its native I/O and browser tasks. |
| `EngineHost/SessionScript.swift` | Pass JSON messages between Swift and the JavaScript session controller. |

`App/Settings` owns settings, MCP enablement, and CLI installation. `App/Unlock` owns the PIN window. `EngineHost/Browser` owns browser setup, downloads, and child processes. `EngineHost/Transport` contains the CLI socket listener, MCP request controls and password pipes, and the extension WebSocket listener. CLI and MCP both compile `Shared/`. `Engine/` holds the JavaScript session code.

## Follow a password request

1. The CLI connects to `CLIListener` in the engine. If needed, it launches the menu app, which starts the engine.
2. `JavaScriptEngine` passes the request to `SessionScript`. The JavaScript controller waits for unlock and serializes credential requests.
3. The controller sends a message through `BridgeListener` to Apple's extension. `BrowserSession` owns the browser that hosts it.
4. If pairing needs a PIN, the engine emits an event to the app. `AppDelegate` presents `PINWindow` and sends the entered code back to the engine.
5. The extension's response returns through the engine to the original CLI connection. The password does not pass through the app's UI event stream.

For MCP, `MCPBroker` maps the request to the same JavaScript operation under a reserved connection ID. It replaces the resulting password with pipe metadata before sending a response. `PasswordPipes` delivers the value to the local consumer. App stdin controls the MCP switch; an MCP request cannot enable it. See [MCP access](mcp.md) for the lifecycle and agent workflow.

The app owns the engine; the engine owns the browser. Quit waits for cleanup. Process generation IDs prevent callbacks from a previous engine from changing the current app state. See [session protocol](session-protocol.md) for the JavaScript state transitions and cancellation rules.

## Build and test

`Aster.xcodeproj` is the build definition. Its **Aster** scheme builds the app plus **AsterCLI**, **AsterEngine**, and **AsterMCP**, and embeds the helpers in the app. MCP uses the official Swift SDK through Swift Package Manager. Source folders stay synchronized with disk; there is no project generation step.

Run `./scripts/build.sh` for the checks and a Debug build, or add `release` for an optimized build and ZIP. For a focused check, use `Tests/App/run.sh`, `Tests/CLI/run.sh`, `Tests/Engine/run.sh`, or `Tests/MCP/run.sh`.
