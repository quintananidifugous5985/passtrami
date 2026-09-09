// SPDX-License-Identifier: GPL-3.0-or-later
// Local request transport adapted from APW 1.1.1 src/daemon.ts.
import { startBrowser, type BrowserProcess } from "./browser.ts";
import { resolveBrowser } from "./runtime.ts";
import { accountsMessage, credentialsFrom, normalizeDomain, onePassword, passwordMessage, RequestError, usernamesFrom } from "./credentials.ts";

const args = new Map<string, string>();
for (let i = 0; i < Deno.args.length; i += 2) args.set(Deno.args[i], Deno.args[i + 1]);
const resources = args.get("--resources"), dataDir = args.get("--data-dir");
if (!resources || !dataDir) { console.error("aster-engine requires --resources and --data-dir"); Deno.exit(64); }
await Deno.mkdir(dataDir, { recursive: true, mode: 0o700 });
await Deno.chmod(dataDir, 0o700);
const socketPath = `${dataDir}/aster.sock`;
const encoder = new TextEncoder();
let token: string | null = null;
let phase = "starting";
let phaseMessage: string | undefined;
let nativeState = "";
let ws: WebSocket | null = null;
let browser: BrowserProcess | null = null;
let launching: Promise<void> | null = null;
let generation = 0;
let launchController: AbortController | null = null;
let stopping: Promise<void> | null = null;
let shuttingDown = false;
let appUnlockRequested = false;
let challengeSent = false;
let pinSubmitted = false;
let queue: Promise<unknown> = Promise.resolve();
type Timer = ReturnType<typeof setTimeout>;
type Waiter = { resolve(): void; reject(error: Error): void; timer?: Timer; signal?: AbortSignal; abort?: () => void };
const unlockWaiters = new Set<Waiter>();
let pending: { id: string; resolve(data: Record<string, unknown>): void; reject(error: Error): void; timer: Timer } | null = null;

function emit(value: unknown) { console.log(JSON.stringify(value)); }
function setPhase(state: string, message?: string) {
  if (phase !== state || phaseMessage !== message) {
    phase = state; phaseMessage = message;
    emit({ type: "state", state, ...(message ? { message } : {}) });
  }
}
function resolveWaiters(error?: Error) {
  for (const item of unlockWaiters) {
    clearTimeout(item.timer);
    if (item.abort) item.signal?.removeEventListener("abort", item.abort);
    error ? item.reject(error) : item.resolve();
  }
  unlockWaiters.clear();
}
function rejectPending(error: Error) {
  if (!pending) return;
  clearTimeout(pending.timer); pending.reject(error); pending = null;
}
function send(value: unknown) {
  if (!ws || ws.readyState !== WebSocket.OPEN) throw new RequestError("locked", "The password session is not connected.");
  ws.send(JSON.stringify(value));
}
function beginChallenge() {
  if (!(appUnlockRequested || unlockWaiters.size) || challengeSent || nativeState !== "NotInSession" || !ws) return;
  challengeSent = true;
  setPhase("pairing");
  send({ op: "unlock" });
}
function stateChanged(raw: string) {
  const previous = nativeState;
  if (raw === previous) return;
  nativeState = raw;
  if (previous === "SessionKeySet") {
    rejectPending(new RequestError("locked", "Apple locked the password session."));
  }
  if (raw === "SessionKeySet") {
    pinSubmitted = false; appUnlockRequested = false; challengeSent = false;
    setPhase("unlocked"); resolveWaiters();
  } else if (raw === "MSG1Set") {
    setPhase("pairing");
    emit({ type: "pinRequired" });
  } else if (raw === "ChallengeSent") {
    setPhase("pairing");
  } else if (raw === "NotInSession") {
    const invalidPIN = pinSubmitted;
    const interrupted = challengeSent && !invalidPIN;
    pinSubmitted = false; challengeSent = false;
    setPhase("locked");
    if (interrupted) {
      void lock(new RequestError("cancelled", "Apple cancelled the unlock request. Try Unlock again."));
    } else {
      if (invalidPIN) emit({ type: "pinError", message: "The code was not accepted. Enter the new code shown by macOS." });
      beginChallenge();
    }
  } else if (raw === "NativeSupportNotInstalled" || raw === "IncompatibleOS") {
    appUnlockRequested = false;
    const error = new RequestError("native_helper", "Apple's password helper did not connect to Chromium.");
    setPhase("error", error.message); resolveWaiters(error); rejectPending(error);
  } else if (raw === "Connecting") {
    setPhase("starting");
  } else if (raw === "CheckEngine") {
    setPhase("locked");
  }
}

const wsServer = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen() {} }, (req) => {
  if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket required", { status: 426 });
  const upgraded = Deno.upgradeWebSocket(req);
  const candidate = upgraded.socket;
  const current = generation;
  let accepted = false;
  const timeout = setTimeout(() => { if (!accepted) candidate.close(); }, 5000);
  candidate.addEventListener("message", (event) => {
    let message: Record<string, unknown>;
    try { message = JSON.parse(event.data); } catch { candidate.close(); return; }
    if (!accepted) {
      if (!token || current !== generation || message.token !== token || ws) { candidate.close(); return; }
      accepted = true; ws = candidate; clearTimeout(timeout);
      return;
    }
    if (candidate !== ws || current !== generation) { candidate.close(); return; }
    if (message.type === "nativeState" && typeof message.state === "string") stateChanged(message.state);
    else if (pending && message.id === pending.id) {
      const request = pending; pending = null; clearTimeout(request.timer);
      if (message.data && typeof message.data === "object") request.resolve(message.data as Record<string, unknown>);
      else request.reject(new RequestError(message.status === 9 ? "locked" : "native_error", "Apple's helper could not complete the request."));
    }
  });
  candidate.addEventListener("close", () => {
    clearTimeout(timeout);
    if (ws === candidate) {
      void lock(new RequestError("locked", "The password session closed."));
    }
  });
  return upgraded.response;
});

async function launch() {
  if (stopping) await stopping;
  if (browser || launching || shuttingDown) return launching;
  const current = ++generation;
  const controller = new AbortController();
  launchController = controller;
  token = crypto.randomUUID();
  setPhase("starting");
  launching = (async () => {
    const executable = await resolveBrowser(dataDir!, controller.signal, (message) => {
      if (current === generation && !shuttingDown) setPhase("starting", message);
    });
    if (current !== generation || shuttingDown) return;
    setPhase("starting", "Starting Chromium…");
    const child = await startBrowser(executable, resources!, dataDir!, { port: wsServer.addr.port, token: token! }, controller.signal);
    if (current !== generation || shuttingDown) { await child.stop(); return; }
    browser = child;
    child.exited.then(() => {
      if (browser === child) void lock(new RequestError("locked", "The browser stopped."));
    });
  })().catch((error) => {
    if (current !== generation) return;
    appUnlockRequested = false;
    const message = error instanceof Error ? error.message : "The browser could not start.";
    setPhase("error", message); resolveWaiters(new RequestError("startup", message));
  }).finally(() => { launching = null; });
  return launching;
}

async function requestUnlock(fromApp = false) {
  if (phase === "unlocked") return;
  if (fromApp) appUnlockRequested = true;
  await launch();
  beginChallenge();
}

function ensureUnlocked(signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(new RequestError("cancelled", "Request cancelled."));
  if (phase === "unlocked") return Promise.resolve();
  return new Promise<void>((resolve, reject) => {
    const item: Waiter = { resolve, reject, signal };
    const remove = (error: Error) => {
      unlockWaiters.delete(item); clearTimeout(item.timer);
      if (item.abort) signal?.removeEventListener("abort", item.abort);
      reject(error);
      if (!appUnlockRequested && !unlockWaiters.size && phase !== "unlocked") void lock(error);
    };
    item.abort = () => remove(new RequestError("cancelled", "Request cancelled."));
    item.timer = setTimeout(() => remove(new RequestError("timeout", "Unlock timed out.")), 900000);
    signal?.addEventListener("abort", item.abort, { once: true });
    unlockWaiters.add(item);
    requestUnlock().catch((error) => remove(error));
  });
}

function lock(error: Error = new RequestError("cancelled", "The password session was locked or cancelled.")): Promise<void> {
  if (stopping) return stopping;
  appUnlockRequested = false; challengeSent = false; pinSubmitted = false; generation++; token = null;
  launchController?.abort(); launchController = null;
  resolveWaiters(error); rejectPending(error);
  const child = browser; browser = null;
  const oldSocket = ws; ws = null; oldSocket?.close(); nativeState = "";
  const oldLaunch = launching;
  stopping = (async () => {
    if (child) await child.stop();
    if (oldLaunch) await oldLaunch;
    setPhase("locked");
  })().finally(() => { stopping = null; });
  return stopping;
}

function nativeRequest(message: unknown, signal: AbortSignal): Promise<Record<string, unknown>> {
  if (signal.aborted) return Promise.reject(new RequestError("cancelled", "Request cancelled."));
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID();
    const abort = () => { if (pending?.id === id) rejectPending(new RequestError("cancelled", "Request cancelled.")); };
    const cleanup = () => signal.removeEventListener("abort", abort);
    pending = { id, resolve: (data) => { cleanup(); resolve(data); }, reject: (error) => { cleanup(); reject(error); },
      timer: setTimeout(() => { if (pending?.id === id) rejectPending(new RequestError("timeout", "Apple's authentication request timed out.")); }, 120000) };
    signal.addEventListener("abort", abort, { once: true });
    try { send({ ...message as object, id }); } catch (error) { rejectPending(error as Error); }
  });
}

async function handleRequest(request: Record<string, unknown>, signal: AbortSignal) {
  const domain = normalizeDomain(request.domain);
  const list = request.op === "list";
  const username = typeof request.username === "string" ? request.username : "";
  if (!list && (!username || username.includes("\n"))) throw new RequestError("invalid_request", "Username is required.");
  const message = list ? accountsMessage(domain) : passwordMessage(domain, username);
  for (let attempt = 0; attempt < 2; attempt++) {
    await ensureUnlocked(signal);
    let data: Record<string, unknown>;
    try {
      data = await nativeRequest(message, signal);
    } catch (error) {
      // Native replies have no reliable request ID. Destroy this session before another request can run.
      await lock(error instanceof RequestError ? error : new RequestError("native_error", "The request failed."));
      if (!(error instanceof RequestError) || error.code !== "locked" || attempt) throw error;
      continue;
    }
    try {
      if (list) return { ok: true, usernames: usernamesFrom(data, domain) };
      const credentials = credentialsFrom(data, domain, username);
      return { ok: true, password: onePassword(credentials) };
    } catch (error) {
      if (!(error instanceof RequestError) || error.code !== "locked" || attempt) throw error;
      await lock(error);
    }
  }
  throw new RequestError("locked", "The password session is locked.");
}

async function writeAll(conn: Deno.Conn, value: unknown) {
  const bytes = encoder.encode(JSON.stringify(value) + "\n");
  for (let offset = 0; offset < bytes.length;) offset += await conn.write(bytes.subarray(offset));
}

async function handleConnection(conn: Deno.Conn) {
  const controller = new AbortController();
  const deadline = setTimeout(() => { controller.abort(); try { conn.close(); } catch { /* Closed. */ } }, 1020000);
  try {
    let line = "";
    const decoder = new TextDecoder();
    const buffer = new Uint8Array(4096);
    while (!line.includes("\n")) {
      const count = await conn.read(buffer);
      if (count === null) return;
      line += decoder.decode(buffer.subarray(0, count), { stream: true });
      if (line.length > 65536) throw new RequestError("invalid_request", "Request is too large.");
    }
    const request = JSON.parse(line.split("\n")[0]);
    if (request.op === "status") {
      await writeAll(conn, { ok: true, state: phase, ...(phaseMessage ? { message: phaseMessage } : {}) });
      return;
    }
    if (request.op !== "get" && request.op !== "list") throw new RequestError("invalid_request", "Unknown command.");
    // Once the request is read, EOF means the CLI cancelled. No second request is accepted on this connection.
    conn.read(new Uint8Array(1)).then(() => controller.abort()).catch(() => controller.abort());
    const work = queue.then(() => {
      if (controller.signal.aborted) throw new RequestError("cancelled", "Request cancelled.");
      return handleRequest(request, controller.signal);
    });
    queue = work.catch(() => {});
    await writeAll(conn, await work);
  } catch (error) {
    if (!controller.signal.aborted) await writeAll(conn, {
      ok: false, code: error instanceof RequestError ? error.code : "internal",
      message: error instanceof RequestError ? error.message : "The request failed."
    }).catch(() => {});
  } finally { clearTimeout(deadline); try { conn.close(); } catch { /* Closed. */ } }
}

try { await Deno.remove(socketPath); } catch (error) { if (!(error instanceof Deno.errors.NotFound)) throw error; }
const listener = Deno.listen({ transport: "unix", path: socketPath });
await Deno.chmod(socketPath, 0o600);
emit({ type: "state", state: "starting" });

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  listener.close();
  await lock();
  await wsServer.shutdown();
  await Deno.remove(socketPath).catch(() => {});
  Deno.exit(0);
}
for (const signal of ["SIGTERM", "SIGINT"] as const) Deno.addSignalListener(signal, shutdown);

(async () => {
  let text = "";
  const decoder = new TextDecoder();
  for await (const bytes of Deno.stdin.readable) {
    text += decoder.decode(bytes, { stream: true });
    let newline;
    while ((newline = text.indexOf("\n")) >= 0) {
      const line = text.slice(0, newline); text = text.slice(newline + 1);
      try {
        const command = JSON.parse(line);
        if (command.op === "shutdown") return await shutdown();
        if (command.op === "lock") await lock();
        else if (command.op === "unlock") void requestUnlock(true);
        else if (command.op === "pin" && /^\d{6}$/.test(command.pin) && nativeState === "MSG1Set") {
          pinSubmitted = true; send({ op: "pin", pin: command.pin });
        }
      } catch { emit({ type: "pinError", message: "The request could not be completed. Try Unlock again." }); }
    }
  }
  await shutdown();
})();
launch();
while (!shuttingDown) {
  let conn: Deno.Conn;
  try {
    conn = await listener.accept();
  } catch (error) {
    if (shuttingDown) break;
    // On macOS, Deno reports EINVAL when a queued Unix client closes before accept.
    // That client is gone, but the listener can still accept the next connection.
    if (error instanceof TypeError && error.message === "Invalid argument (os error 22)") continue;
    throw error;
  }
  void handleConnection(conn);
}
