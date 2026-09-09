# Agent access to secrets

Research and local inspection: September 9, 2026. Installed 1Password version: 8.12.36.

1Password separates the model's request from the process that receives a secret. It has several interfaces with different properties. The [integration overview](https://www.1password.dev/get-started/build-integrations) covers CLI, SDK, and Connect access, including desktop approval and service accounts. These interfaces alone do not prevent secret disclosure in a transcript.

## Environments MCP server

The desktop app includes `1password-mcp`, a local stdio MCP server. Its tools authenticate, manage Environments, list variable names, and create local `.env` mounts. There is no tool to return secret values. These are developer Environments, not a general interface to search and retrieve website passwords. The [official plugin source](https://github.com/1Password/1password-kiro-plugin/blob/main/POWER.md) documents the tool contract. The [July 2026 announcement](https://1password.com/blog/the-1password-environments-mcp-server-is-now-on-cursor-marketplace) describes the approval flow and metadata-only responses.

The actual values travel through a UNIX named pipe at the requested `.env` path. The application reads that pipe and receives plaintext in its process, while the model receives metadata and the path. 1Password does not persist the pipe's contents as a plaintext file.

This has an important limit: 1Password documents that, once the pipe is unlocked, other processes can read it until 1Password locks or the mount is disabled. It does not distinguish reader processes. Therefore, a model with unrestricted shell access can still cause the pipe's contents to enter tool output. A metadata-only MCP interface is not an operating-system isolation boundary. See [local .env file implementation and limitations](https://www.1password.dev/environments/local-env-file).

## CLI and SDK

`op run` resolves secret references such as `op://vault/item/field` and passes the values through the child process environment. It masks secrets in stdout and stderr by default. This reduces accidental transcript exposure, but the child still receives the values. Output masking must not be treated as protection against arbitrary code that can transform or transmit a secret. See the [run command](https://www.1password.dev/cli/reference/commands/run).

The [SDK agent tutorial](https://www.1password.dev/sdks/ai-agent) resolves selected references in Python and passes the results to Browser Use as `sensitive_data`. The prompt uses placeholder names. The application runtime holds the actual values. The page now explicitly says this example is not 1Password's recommended integration approach. Do not infer a general secrecy guarantee from it.

## Agentic Autofill

This is a separate browser integration. The agent requests a login for a website; the user approves the request and can select an account. Credentials travel from the approving 1Password device to the browser extension through an encrypted Noise-based channel. The extension fills the login form, outside the model's normal tool response. Pairing validates the partner, and keys rotate after autofill. Current public setup instructions name Browserbase Director and Early Access; they do not establish an unrestricted API for any app. See [Agentic Autofill](https://www.1password.dev/agentic-autofill).

The documentation describes keeping credentials out of the model's normal workflow. It does not establish that arbitrary browser code cannot read credentials after insertion into a page.

## Local test

- The bundled MCP server initialized and returned eight tool schemas.
- Desktop authentication succeeded.
- Creating and listing the isolated `Aster integration test 2026-09-09` Environment succeeded.
- Adding a generated, concealed test variable failed with MCP error `-32603`: `An unexpected error occurred while updating variables`.
- The account UI showed **Account Frozen**. The Environment remained empty, with no mounted workflows. Editing controls were absent. [Frozen accounts restrict editing and browser filling](https://support.1password.com/frozen-account/).

Secret delivery through the pipe was not tested. The user then limited this work to explaining MCP, so no CLI or SDK credential-read test was performed. No real password was requested or printed. The generated value stayed inside the local test process and was not logged. Test processes were stopped. One empty test Environment remains in 1Password; its editing and deletion controls were unavailable in this account state.

## Implications for Aster

Currently, `aster get` deliberately writes the password to stdout. Calling it directly as an agent tool puts that password in the tool result. Touch ID approval does not change this.

For routine transcript protection, Aster's [MCP interface](mcp.md) delivers a credential through a temporary UNIX pipe and returns only metadata. An agent specifies the website and account. A local program reads the password from the pipe and uses it outside model messages. The pipe permits one delivery, expires after 60 seconds, and is removed on lock, disable, or shutdown.

For a stronger guarantee, the agent must also be unable to replace the consumer, request raw `get` output, read its memory or input pipe, or change the credential destination. Aster's MCP interface does not enforce that isolation when the agent retains unrestricted local execution.
