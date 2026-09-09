# MCP access

Enable **Settings → MCP → Enable MCP**, then select **Copy Configuration**. Add that JSON to a client that supports stdio MCP. The helper is `aster-mcp` inside the current app's Resources folder. It starts Aster by bundle identifier when needed. It does not need the CLI shortcut, a network port, or a second password engine.

MCP is disabled until enabled in the app. The helper cannot change this setting. Initialization and static documentation remain available while disabled, but account and password access is rejected by the engine. `status` reports the setting without starting authentication.

## Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `status` | None | MCP enabled state and password session state. |
| `list_accounts` | `domain` | Account names for the domain; no passwords. |
| `prepare_password` | `domain`, `username` | `lease_id`, `path`, `expires_at`, `format: "utf8"`, `single_use: true`. |
| `revoke_password` | `lease_id` | Removes an unused pipe owned by this MCP session. |

`prepare_password` uses the same domain matching and exact username check as the CLI. It waits for the existing unlock flow when required. Apple controls authentication; a request does not guarantee a new Touch ID prompt. The tool returns only after it has prepared the password for delivery.

The helper uses the official Swift MCP SDK. It supplies initialization instructions and the static resource `aster://docs/credential-access`. Resource reads cannot access a password pipe. MCP errors use fixed messages, not raw native credential responses.

## Agent flow

1. Read `aster://docs/credential-access`.
2. Call `status`. If disabled, ask the user to enable MCP in Settings.
3. Call `list_accounts` if the account is not known. Do not guess which account the user wants.
4. Call `prepare_password` with the domain and exact username. Let the user complete system authentication and the PIN prompt.
5. Start the program that needs the password. Pass only the returned path to that program. It must read the pipe internally and use the value without printing or logging it.
6. If the operation is cancelled before use, call `revoke_password`.

A Python consumer can receive the path as an argument and pass the value directly to its login implementation:

```python
import sys
from pathlib import Path

# The path is metadata. The password stays in this program.
password = Path(sys.argv[1]).read_bytes().decode("utf-8")
if not password:
    raise SystemExit("Password access was cancelled. Request a new pipe.")
# Call the application's login function with password here.
# Return only the nonsecret outcome. Do not print password or exception payloads.
```

This example only shows consumption. Each application must supply its actual login operation. Do not run this consumer just to inspect the value: that would consume the one-use pipe without completing the requested operation.

## Delivery and limits

The engine creates a mode `0600` FIFO in its mode `0700` `password-pipes` directory. It retains the value only in memory until a reader connects. It opens the writer without blocking, checks the FIFO identity, removes the path, and writes the UTF-8 password once, with no newline. Credentials larger than `PIPE_BUF` (512 bytes on macOS) are rejected so delivery fits one atomic write.

An unused pipe expires after 60 seconds. At most 16 pipes and 16 pending MCP account/password requests are allowed. A read attempt consumes the lease, including a reader that closes early. Revocation releases a waiting reader without sending a password; the consumer must treat an empty read as failure. There is no retry of that lease; request a new one if needed.

Lock, loss of the unlocked state, browser shutdown, MCP disable, and app shutdown revoke unused pipes. Explicit lock and MCP disable cancel pending MCP requests. A normal helper shutdown revokes its session's leases. If the helper is killed, the 60-second expiry still applies. Engine restart removes stale FIFO paths. A failed metadata response also revokes its pipe.

Once a value is delivered, Aster cannot remove it from the consumer's memory. FIFO permissions do not isolate two processes running as the same user. Multiple readers must not open one lease. This design keeps passwords out of normal MCP messages; it does not stop unrestricted local code from reading a pipe, running `aster get`, or printing a password. Never send the pipe contents to an agent tool result, log, or transcript.
