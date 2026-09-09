// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from APW 1.1.1 src/browser.ts; uses a verified browser and private profile.
import bridge from "./bridge.js" with { type: "text" };
import { RequestError } from "./credentials.ts";

const nativeHost = "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper";

function cancellationError(): RequestError {
  return new RequestError("cancelled", "Browser startup was cancelled.");
}

function checkCancelled(signal: AbortSignal): void {
  if (signal.aborted) throw cancellationError();
}

function waitForRetry(signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const abort = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      reject(cancellationError());
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, 100);
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
}

async function copyDirectory(source: string, target: string, signal: AbortSignal): Promise<void> {
  checkCancelled(signal);
  await Deno.mkdir(target, { recursive: true, mode: 0o700 });
  for await (const item of Deno.readDir(source)) {
    checkCancelled(signal);
    const from = `${source}/${item.name}`, to = `${target}/${item.name}`;
    if (item.isDirectory) await copyDirectory(from, to, signal);
    else if (item.isFile) await Deno.copyFile(from, to);
  }
  checkCancelled(signal);
}

export interface BrowserProcess { stop(): Promise<void>; exited: Promise<Deno.CommandStatus>; }

export async function startBrowser(executable: string, resources: string, dataDir: string, config: { port: number; token: string }, signal: AbortSignal): Promise<BrowserProcess> {
  checkCancelled(signal);
  await Deno.stat(executable);
  await Deno.stat(nativeHost);
  checkCancelled(signal);
  const runtime = await Deno.makeTempDir({ dir: dataDir, prefix: "session-" });
  const profile = `${runtime}/profile`, extension = `${runtime}/extension`;
  let child: Deno.ChildProcess | undefined;
  let stopPromise: Promise<void> | undefined;
  function stop(): Promise<void> {
    return stopPromise ??= (async () => {
      try {
        if (child) {
          try { child.kill("SIGTERM"); } catch { /* Already exited. */ }
          const timer = setTimeout(() => { try { child?.kill("SIGKILL"); } catch { /* Already exited. */ } }, 3000);
          try { await child.status; } finally { clearTimeout(timer); }
        }
      } finally {
        await Deno.remove(runtime, { recursive: true }).catch(() => {});
      }
    })();
  }
  // Stop the process at once; the startup catch waits for it and removes the profile.
  const abortStartup = () => { try { child?.kill("SIGTERM"); } catch { /* Already exited. */ } };
  signal.addEventListener("abort", abortStartup, { once: true });
  try {
    checkCancelled(signal);
    await Deno.chmod(runtime, 0o700);
    await copyDirectory(`${resources}/AppleExtension`, extension, signal);
    const original = await Deno.readTextFile(`${extension}/background.js`, { signal });
    await Deno.writeTextFile(`${extension}/background.js`, `${original}\nself.ASTER_CONFIG=${JSON.stringify(config)};\n${bridge}\n`, { mode: 0o600, signal });
    checkCancelled(signal);
    await Deno.mkdir(`${profile}/NativeMessagingHosts`, { recursive: true, mode: 0o700 });
    await Deno.writeTextFile(`${profile}/NativeMessagingHosts/com.apple.passwordmanager.json`, JSON.stringify({
      name: "com.apple.passwordmanager", description: "Apple Passwords", path: nativeHost, type: "stdio",
      allowed_origins: ["chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"]
    }), { mode: 0o600, signal });
    checkCancelled(signal);
    await Deno.mkdir(`${profile}/Default`, { recursive: true, mode: 0o700 });
    await Deno.writeTextFile(`${profile}/Default/Preferences`, JSON.stringify({
      profile: { default_content_setting_values: { notifications: 2 } },
      browser: { check_default_browser: false }, credentials_enable_service: false,
      password_manager_enabled: false
    }), { mode: 0o600, signal });
    checkCancelled(signal);
    child = new Deno.Command(executable, { args: [
      `--user-data-dir=${profile}`, "--remote-debugging-port=0", "--enable-unsafe-extension-debugging",
      "--headless=new", "--use-mock-keychain", "--disable-features=DialMediaRouteProvider,NativeNotifications,MacAppCodeSignClone", "--no-first-run", "--no-default-browser-check", "--disable-notifications",
      "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows"
    ], stdin: "null", stdout: "null", stderr: "null" }).spawn();
    let debuggerURL = "";
    for (let attempt = 0; attempt < 100; attempt++) {
      checkCancelled(signal);
      try {
        const lines = (await Deno.readTextFile(`${profile}/DevToolsActivePort`, { signal })).trim().split("\n");
        if (/^\d+$/.test(lines[0]) && lines[1]?.startsWith("/devtools/browser/")) {
          debuggerURL = `ws://127.0.0.1:${lines[0]}${lines[1]}`;
          break;
        }
      } catch { /* Browser is starting. */ }
      await waitForRetry(signal);
    }
    checkCancelled(signal);
    if (!debuggerURL) throw new RequestError("browser_start", "Chromium did not start.");
    const socket = new WebSocket(debuggerURL);
    try {
      await new Promise<void>((resolve, reject) => {
        let finished = false;
        const finish = (error?: Error) => {
          if (finished) return;
          finished = true;
          clearTimeout(timer);
          signal.removeEventListener("abort", abort);
          socket.onerror = socket.onopen = socket.onmessage = socket.onclose = null;
          error ? reject(error) : resolve();
        };
        const abort = () => finish(cancellationError());
        const timer = setTimeout(() => finish(new RequestError("extension_start", "The password extension did not load.")), 15000);
        signal.addEventListener("abort", abort, { once: true });
        socket.onerror = () => finish(new RequestError("browser_connection", "Could not connect to Chromium."));
        socket.onclose = () => finish(new RequestError("browser_connection", "Chromium connection closed."));
        socket.onopen = () => {
          try { socket.send(JSON.stringify({ id: 1, method: "Extensions.loadUnpacked", params: { path: extension } })); }
          catch { finish(new RequestError("browser_connection", "Could not connect to Chromium.")); }
        };
        socket.onmessage = (event) => {
          try {
            const message = JSON.parse(event.data);
            if (message.id === 1) finish(message.error ? new RequestError("extension_start", "The password extension could not be loaded.") : undefined);
          } catch { finish(new RequestError("browser_connection", "Chromium sent an invalid response.")); }
        };
        if (signal.aborted) abort();
      });
    } finally { try { socket.close(); } catch { /* Socket already closed. */ } }
    checkCancelled(signal);
    return { stop, exited: child.status };
  } catch (error) {
    await stop();
    throw signal.aborted ? cancellationError() : error;
  } finally {
    signal.removeEventListener("abort", abortStartup);
  }
}
