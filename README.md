# Passtrami

<img src="Assets/AppIcon.icon/Assets/keyhole_light.png" width="200" height="200" alt="Passtrami light icon">

[**Download for macOS**](https://github.com/zats/passtrami/releases/latest/download/Passtrami.zip) · Apple silicon · macOS 26.2+

Apple Passwords for AI agents.

- Local MCP access without password values in tool responses.
- A menu bar app for setup and unlocking.
- An optional CLI for Terminal and scripts.

Passtrami builds on [APW](https://github.com/bendews/apw), with a macOS interface for setup and daily use. Its MCP design takes inspiration from [1Password’s Environments MCP server](https://www.1password.dev/environments/mcp-server): send passwords to the program that needs them without putting them in MCP responses.

## MCP

Enable MCP in **Settings → Tools**, select **Copy Configuration**, and add it to your agent’s MCP settings. See [MCP access](docs/mcp.md) for details.

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
