// All accounts, passwords, extension messages, and browser processes are fixtures.
import { assert, bounded, Fixture, pause, processExists, until } from "./lifecycle_fixture.ts";
import { RequestError } from "./credentials.ts";

Deno.test("status keeps setup and error details until the state changes", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const starting = await fixture.statusResponse();
    assert(starting.state === "starting");
    assert(starting.message === "Starting Chromium…");
    const extension = await fixture.extension(await fixture.nextBrowser(), "NativeSupportNotInstalled");
    await fixture.state("error");
    for (let read = 0; read < 2; read++) {
      const failure = await fixture.statusResponse();
      assert(failure.state === "error");
      assert(failure.message === "Apple's password helper did not connect to Chromium.");
    }
    extension.state("NotInSession");
    await fixture.state("locked");
    assert(!("message" in await fixture.statusResponse()), "Locked status kept the previous error");
  } finally { await fixture.dispose(); }
});

Deno.test("lock closes the old socket and rejects its previous launch token", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const browser = await fixture.nextBrowser();
    const extension = await fixture.extension(browser);
    await fixture.state("locked");
    extension.state("SessionKeySet");
    await fixture.state("unlocked");
    const eventCount = fixture.events.length;
    await fixture.command("lock");
    await fixture.state("locked");
    await bounded(extension.closed, "Lock did not close the authenticated socket");
    const stale = await fixture.extension(browser, "SessionKeySet");
    await bounded(stale.closed, "The engine accepted a stale launch token");
    assert(await fixture.status() === "locked");
    assert(!fixture.events.slice(eventCount).some((event) => event.state === "unlocked"));
    assert(!processExists(browser.pid), "Lock left its browser running");
  } finally { await fixture.dispose(); }
});

Deno.test("duplicate locked state does not cancel a pending unlock challenge", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const browser = await fixture.nextBrowser();
    const extension = await fixture.extension(browser);
    await fixture.state("locked");
    await fixture.command("unlock");
    await until(() => extension.messages.find((message) => message.op === "unlock"), "No unlock challenge");
    extension.state("NotInSession");
    extension.state("NotInSession");
    await pause(50);
    assert(await fixture.status() === "pairing", "Duplicate locked state cancelled the challenge");
    assert(processExists(browser.pid));
    assert(extension.messages.filter((message) => message.op === "unlock").length === 1);
    extension.state("ChallengeSent");
    extension.state("MSG1Set");
    await until(() => fixture.events.find((event) => event.type === "pinRequired"), "No PIN event");
    assert(await fixture.status() === "pairing", "A challenge state unlocked the engine");
    extension.state("SessionKeySet");
    await fixture.state("unlocked");
  } finally { await fixture.dispose(); }
});

Deno.test("native reconnect clears unlocked state until fresh capabilities arrive", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const extension = await fixture.extension(await fixture.nextBrowser());
    await fixture.state("locked");
    extension.state("SessionKeySet");
    await fixture.state("unlocked");
    extension.state("Connecting");
    await fixture.state("starting");
    assert(await fixture.status() !== "unlocked", "Reconnect left the engine unlocked");
    extension.state("NotInSession");
    await fixture.state("locked");
  } finally { await fixture.dispose(); }
});

Deno.test("a locked list waits for unlock and returns only unique usernames", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const extension = await fixture.extension(await fixture.nextBrowser());
    await fixture.state("locked");
    const list = await fixture.connectList("https://EXAMPLE.test/path");
    await until(() => extension.messages.find((message) => message.op === "unlock"), "List did not request unlock");
    assert([...extension.requests].length === 0, "List reached the native helper before unlock");
    extension.state("SessionKeySet");
    const request = await until(() => extension.requests[0], "List did not reach the native helper after unlock");
    assert(request.cmd === 4 && request.body.ACT === 5 && request.body.URL === "example.test");
    extension.reply(request, { STATUS: 0, Entries: [
      { USR: "person@example.test", sites: ["example.test"], PWD: "fixture-secret" },
      { USR: "person@example.test", sites: ["accounts.example.test"], PWD: "Not Included" },
    ] });
    const response = await fixture.response(list);
    assert(JSON.stringify(response) === '{"ok":true,"usernames":["person@example.test"]}');
    assert(extension.requests.length === 1, "List also sent a password request");
  } finally { await fixture.dispose(); }
});

Deno.test("a cancelled queued list sends no native request", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const extension = await fixture.extension(await fixture.nextBrowser());
    extension.autoUnlock = true;
    const first = await fixture.connectRequest("first@example.test");
    await until(() => extension.requests[0], "First get did not reach the extension");
    const cancelled = await fixture.connectList();
    cancelled.close();
    await pause(50);
    extension.reply(extension.requests[0]);
    assert(JSON.stringify(await fixture.response(first)) === '{"ok":true,"password":"fixture-password"}');
    const next = await fixture.connectList();
    await until(() => extension.requests[1], "Next list did not reach the extension");
    assert(extension.requests[1].cmd === 4);
    extension.reply(extension.requests[1], { STATUS: 3 });
    assert(JSON.stringify(await fixture.response(next)) === '{"ok":true,"usernames":[]}');
    assert(extension.requests.length === 2, "Cancelled list reached the extension");
  } finally { await fixture.dispose(); }
});

Deno.test("an in-flight list cancellation destroys the session before the next get", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const firstBrowser = await fixture.nextBrowser();
    const firstExtension = await fixture.extension(firstBrowser);
    firstExtension.autoUnlock = true;
    const list = await fixture.connectList();
    await until(() => firstExtension.requests[0], "List did not reach the extension");
    assert(firstExtension.requests[0].cmd === 4);
    const next = await fixture.connectRequest("next@example.test");
    list.close();
    const nextBrowser = await fixture.nextBrowser([firstBrowser.pid]);
    assert(!processExists(firstBrowser.pid), "Next get started before the cancelled list session stopped");
    await bounded(firstExtension.closed, "Cancelled list kept its extension connected");
    assert(firstExtension.requests.length === 1);
    const nextExtension = await fixture.extension(nextBrowser);
    nextExtension.autoUnlock = true;
    if (nextExtension.messages.some((message) => message.op === "unlock")) nextExtension.state("SessionKeySet");
    const request = await until(() => nextExtension.requests[0], "Next get did not reach the new session");
    assert(request.cmd === 5 && request.body.USR === "next@example.test");
    nextExtension.reply(request);
    assert(JSON.stringify(await fixture.response(next)) === '{"ok":true,"password":"fixture-password"}');
    assert(nextBrowser.token !== firstBrowser.token);
  } finally { await fixture.dispose(); }
});

Deno.test("a cancelled queued get sends no native request", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const extension = await fixture.extension(await fixture.nextBrowser());
    extension.autoUnlock = true;
    const first = await fixture.connectRequest("first@example.test");
    await until(() => extension.requests[0], "First request did not reach the extension");
    const cancelled = await fixture.connectRequest("cancelled@example.test");
    cancelled.close();
    await pause(50);
    extension.reply(extension.requests[0]);
    assert((await fixture.response(first)).ok === true);
    const next = await fixture.connectRequest("next@example.test");
    await until(() => extension.requests[1], "Next request did not reach the extension");
    assert(extension.requests[1].body.USR === "next@example.test", "The cancelled request reached the extension");
    extension.reply(extension.requests[1]);
    assert((await fixture.response(next)).ok === true);
    assert(extension.requests.length === 2);
  } finally { await fixture.dispose(); }
});

Deno.test("a client closed before accept does not stop later requests", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const extension = await fixture.extension(await fixture.nextBrowser());
    extension.autoUnlock = true;
    await fixture.state("locked");
    try {
      // Hold the engine so the abandoned request is closed in the listener backlog.
      await fixture.pauseEngine();
      const cancelled = await fixture.connectRequest("cancelled@example.test");
      cancelled.close();
    } finally { fixture.resumeEngine(); }
    const next = await fixture.connectRequest("next@example.test");
    await until(() => extension.requests[0], "The listener stopped after a cancelled client");
    assert(extension.requests[0].body.USR === "next@example.test", "The cancelled request reached the extension");
    extension.reply(extension.requests[0]);
    assert((await fixture.response(next)).ok === true);
    assert(await fixture.status() === "unlocked");
    assert(extension.requests.length === 1);
  } finally { await fixture.dispose(); }
});

Deno.test("in-flight cancellation destroys its session before the next get", async () => {
  const fixture = await Fixture.create();
  try {
    await fixture.startEngine();
    const firstBrowser = await fixture.nextBrowser();
    const firstExtension = await fixture.extension(firstBrowser);
    firstExtension.autoUnlock = true;
    const first = await fixture.connectRequest("first@example.test");
    await until(() => firstExtension.requests[0], "First request did not reach the extension");
    const next = await fixture.connectRequest("next@example.test");
    first.close();
    const nextBrowser = await fixture.nextBrowser([firstBrowser.pid]);
    assert(!processExists(firstBrowser.pid), "Next session started before the old browser exited");
    await bounded(firstExtension.closed, "Cancellation did not close the old extension");
    assert(firstExtension.requests.length === 1, "A second request used the cancelled session");
    const nextExtension = await fixture.extension(nextBrowser);
    nextExtension.autoUnlock = true;
    // The initial state can reach the engine before autoUnlock is set.
    if (nextExtension.messages.some((message) => message.op === "unlock")) nextExtension.state("SessionKeySet");
    await until(() => nextExtension.requests[0], "Next request did not reach the new session");
    assert(nextExtension.requests[0].body.USR === "next@example.test");
    nextExtension.reply(nextExtension.requests[0]);
    assert((await fixture.response(next)).ok === true);
    assert(nextBrowser.token !== firstBrowser.token, "The new session reused the previous token");
  } finally { await fixture.dispose(); }
});

for (const mode of ["wait-ready", "wait-cdp"]) {
  Deno.test(`startup abort stops its child and removes its profile during ${mode}`, async () => {
    const fixture = await Fixture.create(mode);
    const controller = new AbortController();
    const startup = fixture.startBrowser(controller.signal);
    // Attach rejection handling before abort to avoid an unhandled test promise.
    const result = startup.then(() => undefined, (error) => error);
    try {
      const browser = await fixture.nextBrowser();
      if (mode === "wait-cdp") {
        await until(async () => await Deno.stat(`${fixture.root}/sessions/${browser.pid}.cdp`).then(() => true, () => false),
          "The fake CDP command was not received");
      }
      controller.abort();
      const error = await bounded(result, "Startup did not stop promptly after abort", 4000);
      assert(error instanceof RequestError && error.code === "cancelled");
      assert(!processExists(browser.pid), "Startup abort left its child running");
      const entries = [];
      for await (const entry of Deno.readDir(fixture.dataDir)) entries.push(entry.name);
      assert(entries.length === 0, "Startup abort left a session profile");
      assert(await Deno.readTextFile(`${fixture.root}/sessions/${browser.pid}.stopped`) === "SIGTERM");
    } finally {
      controller.abort();
      await result;
      await fixture.dispose();
    }
  });
}
