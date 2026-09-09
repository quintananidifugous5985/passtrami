// Test-only browser and extension. Never connects to Apple's native helper.
import { startBrowser } from "./browser.ts";

export function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}

export const pause = (milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

export async function until<T>(read: () => T | Promise<T>, message: string, timeout = 5000): Promise<NonNullable<T>> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await read();
    if (value) return value as NonNullable<T>;
    await pause(10);
  }
  throw new Error(message);
}

export async function bounded<T>(promise: Promise<T>, message: string, timeout = 5000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), timeout);
    })]);
  } finally { clearTimeout(timer); }
}

type BrowserInfo = { pid: number; port: number; token: string };
type Message = Record<string, any>;

export function processExists(pid: number): boolean {
  try { Deno.kill(pid, 0); return true; } catch { return false; }
}

export class Extension {
  readonly messages: Message[] = [];
  readonly socket: WebSocket;
  readonly closed: Promise<void>;
  autoUnlock = false;

  constructor(readonly browser: BrowserInfo) {
    this.socket = new WebSocket(`ws://127.0.0.1:${browser.port}`);
    this.closed = new Promise((resolve) => this.socket.addEventListener("close", () => resolve()));
    this.socket.addEventListener("error", () => {});
    this.socket.addEventListener("message", ({ data }) => {
      const message = JSON.parse(data);
      this.messages.push(message);
      if (message.op === "unlock" && this.autoUnlock) this.state("SessionKeySet");
    });
  }

  async open(initialState?: string) {
    await bounded(new Promise<void>((resolve, reject) => {
      this.socket.addEventListener("open", () => resolve(), { once: true });
      this.socket.addEventListener("error", () => reject(new Error("Fixture WebSocket did not open")), { once: true });
    }), "Fixture WebSocket timed out");
    this.socket.send(JSON.stringify({ token: this.browser.token }));
    if (initialState) this.state(initialState);
  }

  state(state: string) { this.socket.send(JSON.stringify({ type: "nativeState", state })); }

  get requests(): Message[] { return this.messages.filter((message) => message.cmd === 4 || message.cmd === 5); }

  reply(request: Message, data: Message = {
      STATUS: 0,
      Entries: [{ USR: request.body.USR, sites: [request.body.URL], PWD: "fixture-password" }],
    }) {
    this.socket.send(JSON.stringify({ id: request.id, data }));
  }

  async close() {
    if (this.socket.readyState !== WebSocket.CLOSED) this.socket.close();
    await bounded(this.closed, "Fixture WebSocket did not close");
  }
}

export class Fixture {
  readonly resources: string;
  readonly dataDir: string;
  readonly events: Message[] = [];
  private readonly extensions: Extension[] = [];
  private readonly connections = new Set<Deno.UnixConn>();
  private child?: Deno.ChildProcess;
  private enginePaused = false;
  private writer?: WritableStreamDefaultWriter<Uint8Array>;
  private stdout?: Promise<void>;
  private stderr?: Promise<string>;

  private constructor(readonly root: string) {
    this.resources = `${root}/resources`;
    this.dataDir = `${root}/data`;
  }

  static async create(mode = "ready"): Promise<Fixture> {
    const fixture = new Fixture(await Deno.makeTempDir({ prefix: "aster-lifecycle-" }));
    await Deno.mkdir(`${fixture.resources}/AppleExtension`, { recursive: true });
    await Deno.mkdir(`${fixture.root}/sessions`);
    await Deno.mkdir(fixture.dataDir);
    await Deno.writeTextFile(`${fixture.resources}/AppleExtension/background.js`, "// Empty test extension.\n");
    await Deno.writeTextFile(`${fixture.root}/mode`, mode);
    const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
    const script = new URL(import.meta.url).pathname;
    await Deno.writeTextFile(`${fixture.resources}/browser`,
      `#!/bin/sh\nexec ${quote(Deno.execPath())} run --allow-all --no-check ${quote(script)} ${quote(fixture.root)} "$@"\n`, { mode: 0o700 });
    await Deno.writeTextFile(`${fixture.root}/fake-runtime.ts`,
      `export async function resolveBrowser(..._args: unknown[]): Promise<string> { return ${JSON.stringify(`${fixture.resources}/browser`)}; }\n`);
    await Deno.writeTextFile(`${fixture.root}/import-map.json`, JSON.stringify({ imports: {
      [new URL("./runtime.ts", import.meta.url).href]: new URL(`file://${fixture.root}/fake-runtime.ts`).href,
    } }));
    return fixture;
  }

  async startEngine() {
    this.child = new Deno.Command(Deno.execPath(), {
      args: ["run", "--allow-all", "--no-check", "--import-map", `${this.root}/import-map.json`,
        new URL("./main.ts", import.meta.url).pathname,
        "--resources", this.resources, "--data-dir", this.dataDir],
      stdin: "piped", stdout: "piped", stderr: "piped",
    }).spawn();
    this.writer = this.child.stdin.getWriter();
    this.stderr = new Response(this.child.stderr).text();
    this.stdout = (async () => {
      let buffered = "";
      for await (const text of this.child!.stdout.pipeThrough(new TextDecoderStream())) {
        buffered += text;
        let newline;
        while ((newline = buffered.indexOf("\n")) >= 0) {
          const line = buffered.slice(0, newline);
          buffered = buffered.slice(newline + 1);
          if (line) this.events.push(JSON.parse(line));
        }
      }
    })();
    await this.nextBrowser();
  }

  command(op: string) { return this.writer!.write(new TextEncoder().encode(JSON.stringify({ op }) + "\n")); }

  async pauseEngine() {
    this.child!.kill("SIGSTOP");
    this.enginePaused = true;
    await until(async () => {
      const result = await new Deno.Command("/bin/ps", {
        args: ["-o", "stat=", "-p", String(this.child!.pid)], stdout: "piped", stderr: "null",
      }).output();
      return new TextDecoder().decode(result.stdout).includes("T");
    }, "The fixture engine did not stop");
  }

  resumeEngine() {
    if (!this.enginePaused) return;
    this.child!.kill("SIGCONT");
    this.enginePaused = false;
  }

  async browsers(): Promise<BrowserInfo[]> {
    const result = [];
    for await (const file of Deno.readDir(`${this.root}/sessions`)) {
      if (file.name.endsWith(".json")) {
        result.push(JSON.parse(await Deno.readTextFile(`${this.root}/sessions/${file.name}`)));
      }
    }
    return result;
  }

  nextBrowser(excluding: number[] = []) {
    return until(async () => (await this.browsers()).find((browser) => !excluding.includes(browser.pid)),
      "The fake browser did not start");
  }

  async extension(browser: BrowserInfo, initialState = "NotInSession") {
    const extension = new Extension(browser);
    this.extensions.push(extension);
    await extension.open(initialState);
    return extension;
  }

  connectRequest(username: string) {
    return this.connect({ op: "get", domain: "example.test", username });
  }

  connectList(domain = "example.test") {
    return this.connect({ op: "list", domain });
  }

  private async connect(request: Message) {
    const conn = await Deno.connect({ transport: "unix", path: `${this.dataDir}/aster.sock` });
    this.connections.add(conn);
    await conn.write(new TextEncoder().encode(JSON.stringify(request) + "\n"));
    return conn;
  }

  async response(conn: Deno.UnixConn): Promise<Message> {
    const buffer = new Uint8Array(65536);
    let text = "";
    const decoder = new TextDecoder();
    while (!text.includes("\n")) {
      const count = await bounded(conn.read(buffer), "The fixture request did not complete");
      assert(count !== null, "The fixture request closed without a response");
      text += decoder.decode(buffer.subarray(0, count));
    }
    return JSON.parse(text.split("\n")[0]);
  }

  async statusResponse(): Promise<Message> {
    const conn = await Deno.connect({ transport: "unix", path: `${this.dataDir}/aster.sock` });
    try {
      await conn.write(new TextEncoder().encode('{"op":"status"}\n'));
      return await this.response(conn);
    } finally { conn.close(); }
  }

  async status(): Promise<string> { return (await this.statusResponse()).state; }

  state(expected: string) {
    return until(async () => (await this.status()) === expected, `Engine did not become ${expected}`);
  }

  async dispose() {
    let outputError: unknown;
    try { this.resumeEngine(); } catch { /* Exited. */ }
    for (const conn of this.connections) { try { conn.close(); } catch { /* Closed. */ } }
    for (const extension of this.extensions) await extension.close().catch(() => {});
    if (this.child) {
      try {
        await this.command("shutdown");
        await bounded(this.child.status, "Engine shutdown timed out");
      } catch {
        try { this.child.kill("SIGKILL"); } catch { /* Exited. */ }
        await this.child.status;
      }
      await this.writer?.close().catch(() => {});
      try { await this.stdout; } catch (error) { outputError = error; }
      const stderr = await this.stderr;
      if (stderr?.includes("error:")) outputError = new Error(`Engine failed: ${stderr}`);
    }
    for (const browser of await this.browsers()) {
      if (processExists(browser.pid)) {
        try { Deno.kill(browser.pid, "SIGKILL"); } catch { /* Exited. */ }
        await until(() => !processExists(browser.pid), "Fake browser cleanup failed");
      }
    }
    await Deno.remove(this.root, { recursive: true });
    if (outputError) throw outputError;
  }

  startBrowser(signal: AbortSignal) {
    return startBrowser(`${this.resources}/browser`, this.resources, this.dataDir, { port: 1, token: "test-only" }, signal);
  }
}

async function fakeBrowser() {
  const root = Deno.args[0];
  const profile = Deno.args.find((arg) => arg.startsWith("--user-data-dir="))!.split("=").slice(1).join("=");
  const mode = await Deno.readTextFile(`${root}/mode`);
  const background = await Deno.readTextFile(`${profile}/../extension/background.js`);
  const config = JSON.parse(background.match(/\nself\.ASTER_CONFIG=(.+);\n/)![1]);
  const sockets = new Set<WebSocket>();
  const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen() {} }, (request) => {
    const { socket, response } = Deno.upgradeWebSocket(request);
    sockets.add(socket);
    socket.addEventListener("close", () => sockets.delete(socket));
    socket.addEventListener("message", ({ data }) => {
      const message = JSON.parse(data);
      assert(message.method === "Extensions.loadUnpacked", "Unexpected fake CDP command");
      Deno.writeTextFileSync(`${root}/sessions/${Deno.pid}.cdp`, "ready");
      if (mode !== "wait-cdp") socket.send(JSON.stringify({ id: message.id, result: { id: "test-extension" } }));
    });
    return response;
  });
  Deno.addSignalListener("SIGTERM", () => {
    Deno.writeTextFileSync(`${root}/sessions/${Deno.pid}.stopped`, "SIGTERM");
    for (const socket of sockets) socket.close();
    Deno.exit(0);
  });
  const infoPath = `${root}/sessions/${Deno.pid}.json`;
  await Deno.writeTextFile(`${infoPath}.tmp`, JSON.stringify({ pid: Deno.pid, ...config }));
  await Deno.rename(`${infoPath}.tmp`, infoPath);
  if (mode !== "wait-ready") {
    await Deno.writeTextFile(`${profile}/DevToolsActivePort`, `${server.addr.port}\n/devtools/browser/test\n`);
  }
  await server.finished;
}

if (import.meta.main) await fakeBrowser();
