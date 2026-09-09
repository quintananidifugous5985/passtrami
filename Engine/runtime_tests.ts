import { downloadArchive, isCompatibleVersion, resolveBrowser, runSystemCheck } from "./runtime.ts";
import { RequestError } from "./credentials.ts";

function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}

async function missing(path: string): Promise<boolean> {
  try { await Deno.stat(path); return false; }
  catch (error) { if (error instanceof Deno.errors.NotFound) return true; throw error; }
}

async function fixture(handler: () => Response, test: (url: string, directory: string) => Promise<void>): Promise<void> {
  const directory = await Deno.makeTempDir({ prefix: "aster-runtime-test-" });
  const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen: () => {} }, handler);
  try { await test(`http://127.0.0.1:${server.addr.port}`, directory); }
  finally {
    await server.shutdown();
    await Deno.remove(directory, { recursive: true });
  }
}

Deno.test("system check returns stdout without adding command diagnostics", async () => {
  const result = await runSystemCheck("Test check", "/bin/sh", ["-c", "printf '152.0.7977.82\\n'"], new AbortController().signal);
  assert(result === "152.0.7977.82");
});

Deno.test("system check failures identify the step and exit code without exposing command output", async () => {
  const result = await runSystemCheck("Chromium signature check", "/bin/sh", ["-c", "printf 'private stdout'\nprintf 'private stderr' >&2\nexit 7"], new AbortController().signal)
    .then(() => undefined, (error) => error);
  assert(result instanceof RequestError && result.code === "browser_verify");
  assert(result.message === "Chromium signature check failed (sh, exit 7).");
});

Deno.test("system check timeout stops and reaps the process and identifies the step", async () => {
  const result = await runSystemCheck("Chromium Gatekeeper check", "/bin/sleep", ["10"], new AbortController().signal, 25)
    .then(() => undefined, (error) => error);
  assert(result instanceof RequestError && result.code === "browser_setup");
  assert(result.message === "Chromium Gatekeeper check timed out (sleep).");
});

Deno.test("system check cancellation stops and reaps the process", async () => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 25);
  try {
    const result = await runSystemCheck("Chromium Gatekeeper check", "/bin/sleep", ["10"], controller.signal)
      .then(() => undefined, (error) => error);
    assert(result instanceof RequestError && result.code === "cancelled");
  } finally { clearTimeout(timer); }
});

Deno.test("browser versions use numeric components and reject malformed or older builds", () => {
  for (const version of ["152.0.7977.82", "152.0.7977.83", "152.0.7978.0", "153.0.0.0"]) {
    assert(isCompatibleVersion(version), `Compatible version rejected: ${version}`);
  }
  for (const version of ["151.9.9999.999", "152.0.7977.9", "152.0.7977.81", "152.0.7977", "152.0.7977.82-beta", " 152.0.7977.82", "99999999999999999.0.0.0", "152.0.7977.8e2"]) {
    assert(!isCompatibleVersion(version), `Invalid version accepted: ${version}`);
  }
});

Deno.test("verified downloads retain the exact bytes in a private file", async () => {
  await fixture(() => new Response("abc"), async (url, directory) => {
    const file = `${directory}/browser.dmg`;
    await downloadArchive(url, file, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", new AbortController().signal, () => {});
    assert(await Deno.readTextFile(file) === "abc");
    assert(((await Deno.stat(file)).mode! & 0o777) === 0o600, "The archive is not private");
  });
});

Deno.test("a checksum failure removes the downloaded file", async () => {
  await fixture(() => new Response("unexpected archive"), async (url, directory) => {
    const file = `${directory}/browser.dmg`;
    const result = await downloadArchive(url, file, "0".repeat(64), new AbortController().signal, () => {}).then(() => undefined, (error) => error);
    assert(result instanceof RequestError && result.code === "browser_checksum");
    assert(await missing(file), "Checksum failure left an archive");
  });
});

Deno.test("download cancellation removes a partial file and closes its response", async () => {
  let streamCancelled = false;
  await fixture(() => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode("partial archive")); },
    cancel() { streamCancelled = true; }
  })), async (url, directory) => {
    const file = `${directory}/browser.dmg`;
    const controller = new AbortController();
    const result = await downloadArchive(url, file, "0".repeat(64), controller.signal, () => controller.abort()).then(() => undefined, (error) => error);
    assert(result instanceof RequestError && result.code === "cancelled");
    assert(await missing(file), "Cancellation left a partial archive");
  });
  assert(streamCancelled, "Cancellation left the HTTP response open");
});

Deno.test("an HTTP failure creates no archive", async () => {
  await fixture(() => new Response("unavailable", { status: 503 }), async (url, directory) => {
    const file = `${directory}/browser.dmg`;
    const result = await downloadArchive(url, file, "0".repeat(64), new AbortController().signal, () => {}).then(() => undefined, (error) => error);
    assert(result instanceof RequestError && result.code === "browser_download");
    assert(await missing(file));
  });
});

Deno.test("download refuses to replace a file it does not own", async () => {
  await fixture(() => new Response("abc"), async (url, directory) => {
    const file = `${directory}/browser.dmg`;
    await Deno.writeTextFile(file, "existing file");
    const result = await downloadArchive(url, file, "0".repeat(64), new AbortController().signal, () => {}).then(() => undefined, (error) => error);
    assert(result instanceof Deno.errors.AlreadyExists);
    assert(await Deno.readTextFile(file) === "existing file");
  });
});

Deno.test("cancelled setup creates no cache or staging directory", async () => {
  const directory = await Deno.makeTempDir({ prefix: "aster-runtime-test-" });
  try {
    const controller = new AbortController();
    controller.abort();
    const result = await resolveBrowser(directory, controller.signal, () => { throw new Error("Cancelled setup reported progress"); }).then(() => undefined, (error) => error);
    assert(result instanceof RequestError && result.code === "cancelled");
    const entries = [];
    for await (const entry of Deno.readDir(directory)) entries.push(entry.name);
    assert(entries.length === 0, "Cancelled setup left files");
  } finally { await Deno.remove(directory, { recursive: true }); }
});
