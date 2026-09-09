# Passtrami

A menu bar app and CLI for Apple Passwords on Apple silicon Macs running macOS 26.2 or later. Passtrami uses Apple's password extension in a headless browser. It downloads and caches a pinned Chromium release.

## Use

Place Passtrami in its intended location and open it. On first launch, it prepares the browser and starts pairing. Enter the six-digit code shown by macOS into Passtrami's focused PIN field. The sixth digit submits the code. Apple controls system authentication, including Touch ID when required.

Passtrami checks for app updates daily. Use **Check for Updates…** in the menu to check now, or change automatic checks in **Settings… → Updates**. Sparkle verifies each update before installation.

**Lock** ends Passtrami's browser session. It does not lock the system Keychain or the Passwords app. **Unlock…** starts a new session and pairing flow. Quit stops Passtrami's engine and browser.

In **Settings… → Command Line**, select **Install…**, then open a new terminal window. This creates `~/.local/bin/passtrami` and adds that folder to PATH in `~/.zprofile` and `~/.zshrc`. Once installed, **Uninstall** removes the shortcut. The bundled helper and shared PATH entry remain. **Launch at login** is on by default and can be changed in Settings.

```sh
passtrami get example.com person@example.com
passtrami list example.com
passtrami status
passtrami --help
```

The CLI starts Passtrami by its bundle identifier when needed and waits for unlock. `get` requires an exact username. A stored site can match the requested domain or a subdomain.

- `get`: only the password on stdout, with no trailing newline.
- `list`: one username per line, with duplicates removed. No matches produces no output.
- Errors: a message on stderr and a nonzero exit status. `status` includes setup error details. `get` fails if matching records contain different passwords.

Pairing does not guarantee a new Touch ID prompt for every request. Apple can reuse prior authentication.

## MCP

In **Settings… → MCP**, turn on **Enable MCP**, then select **Copy Configuration**. Add the copied configuration to a client that supports local stdio MCP servers. The command points to the helper inside the current app. Copy it again if you move the app. CLI installation is not required.

MCP is off by default. It can list accounts for a domain and prepare a password for an exact account. The password travels through a temporary UNIX pipe directly to the program that uses it. MCP responses contain only account names, state, and pipe metadata. The pipe allows one delivery and expires after 60 seconds. Lock, Quit, or turning MCP off removes unused pipes.

The server includes instructions and a documentation resource for agents. See [MCP access](docs/mcp.md) for setup, the tools, and a consumer example. Do not run `passtrami get`, `cat` the pipe, or print its contents through an agent tool: those actions expose the value in the transcript.

## Build

Requires Xcode 27. The finished app includes the engine and does not require these build tools. Apple's password browser helper must be available on the Mac.

Run `python3 scripts/prepare-extension.py` before the first Xcode build. Then open `Passtrami.xcodeproj` and run the **Passtrami** scheme, or use the build script below, which prepares the extension for you. Both use the same Xcode targets and build settings. The project uses synchronized folders that follow the layout on disk.

```sh
./scripts/build.sh
open build/Passtrami.app
```

To make an optimized release:

```sh
./scripts/build.sh release
```

The build script runs the JavaScriptCore, native engine, CLI, app utility, and MCP protocol tests, then builds the app and its helpers through Xcode. Release output is `build/Release/Passtrami.app`, a versioned ZIP, and its SHA256 checksum. Builds are ad-hoc signed for local use; they are not Developer ID signed or notarized.

For a signed and notarized public release, follow [Release and updates](docs/releasing.md). The release ZIP is hosted on [GitHub Releases](https://github.com/zats/passtrami/releases); its Sparkle feed is published to [GitHub Pages](https://zats.github.io/passtrami/appcast.xml).

Start with the [native code guide](docs/native-code.md) to follow the entry points, process boundaries, and request flow.

See [browser runtime](docs/browser-runtime.md) for browser setup and download verification, and [session protocol](docs/session-protocol.md) for pairing and request handling.

See [1Password integration research](docs/agent-secret-access.md) for how other integrations keep secret values out of model responses and the limits of those methods.

## Attribution

The engine is adapted from [APW 1.1.1](https://github.com/bendews/apw). Passtrami's APW-derived code is GPL-3.0-or-later; see [LICENSE](LICENSE) and [Vendor/APW](Vendor/APW).
