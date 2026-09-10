# Passtrami

<img src="Assets/AppIcon.icon/Assets/keyhole_light.png" width="200" height="200" alt="Passtrami light icon">

[**Download for macOS**](https://github.com/zats/passtrami/releases/latest/download/Passtrami.zip) · Apple silicon · macOS 26.2+

Apple Passwords for AI agents.

- Local MCP access without password values in tool responses.
- A menu bar app for setup and unlocking.
- An optional CLI for Terminal and scripts.

Passtrami builds on [APW](https://github.com/bendews/apw), with a macOS interface for setup and daily use. Its MCP design takes inspiration from [1Password’s Environments MCP server](https://www.1password.dev/environments/mcp-server): send passwords to the program that needs them without putting them in MCP responses.

## Setup

1. Unzip the download, move Passtrami to `/Applications`, and open it.
2. Wait for Chromium to download, then enter the six-digit code shown by macOS.
3. In **Settings → Tools → MCP**, enable MCP and select **Copy Configuration**.
4. Add the configuration to your agent’s MCP settings. CLI installation is not required.

Passwords travel through a one-use local pipe. The consuming program must not print or log them. See [MCP access](docs/mcp.md) for details and limits.

Launch at Login and automatic app updates are on by default.

## Command line

Install from **Settings → Tools → Command Line**, then open a new terminal window.

```sh
passtrami list example.com
passtrami get example.com person@example.com
passtrami status
passtrami --help
```

`get` prints the password. Use MCP for agents.

## Build

Requires Xcode 27.

```sh
./scripts/build.sh
open build/Passtrami.app
```

See [native code](docs/native-code.md), [browser setup](docs/browser-runtime.md), and [release instructions](docs/releasing.md).

## License and credits

APW-derived code is GPL-3.0-or-later. See [LICENSE](LICENSE) and [Vendor/APW](Vendor/APW).
