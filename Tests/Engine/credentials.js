(() => {
const { accountsMessage, credentialsFrom, normalizeDomain, onePassword, passwordMessage, RequestError, usernamesFrom } = AsterCredentials;

function assert(value, message = "Assertion failed") {
  if (!value) throw new Error(message);
}
function throwsCode(fn, code) {
  try { fn(); } catch (error) { assert(error instanceof RequestError && error.code === code); return; }
  throw new Error(`Expected ${code}`);
}
const fixture = (USR, sites, PWD = "fixture-secret") => ({ USR, sites, PWD });

test("builds the native website and username request", () => {
  const request = passwordMessage("google.com", "person@example.test");
  assert(request.cmd === 5 && request.body.ACT === 2);
  assert(request.body.URL === "google.com" && request.body.USR === "person@example.test");
});
test("builds the native account-list request without requesting passwords", () => {
  const request = accountsMessage("example.test");
  assert(request.cmd === 4 && request.qid === "CmdGetLoginNames4URL");
  assert(request.tabId === 1 && request.frameId === 1 && request.url === "example.test");
  assert(JSON.stringify(request.body) === '{"ACT":5,"URL":"example.test"}');
});
test("account lists filter domains, deduplicate usernames, and exclude password fields", () => {
  const usernames = usernamesFrom({ STATUS: 0, Entries: [
    { ...fixture("person@example.test", ["example.test", "accounts.example.test", "example.test"]), customTitle: "Private title" },
    fixture("person@example.test", ["https://accounts.example.test", "example.test"], "another-secret"),
    fixture("other@example.test", ["accounts.example.test"], "Not Included"),
    fixture("unrelated@example.test", ["example.test.attacker.test", "notexample.test"]),
    fixture("invalid@example.test", ["file:///example.test"]),
    fixture("Passwords\u00a0not\u00a0saved", ["example.test"]),
    { USR: 3, sites: ["example.test"] }, null,
  ] }, "example.test");
  assert(JSON.stringify(usernames) === '["person@example.test","other@example.test"]');
});
test("account lists support numbered entries and an empty result", () => {
  const usernames = usernamesFrom({ STATUS: 0,
    Entry_2: fixture("second", ["example.test"]), Entry_1: fixture("first", ["example.test"]),
  }, "example.test");
  assert(usernames.join(",") === "first,second");
  assert(usernamesFrom({ STATUS: 3 }, "example.test").length === 0);
  assert(usernamesFrom({ STATUS: 0, Entries: [fixture("other", ["other.test"])] }, "example.test").length === 0);
});
test("account lists preserve locked and native errors", () => {
  throwsCode(() => usernamesFrom({ STATUS: 9 }, "example.test"), "locked");
  throwsCode(() => usernamesFrom({ STATUS: 1 }, "example.test"), "native_error");
});
test("normalizes website URLs and rejects non-web schemes or embedded credentials", () => {
  assert(normalizeDomain("https://GOOGLE.com/path") === "google.com");
  assert(normalizeDomain("google.com.") === "google.com");
  throwsCode(() => normalizeDomain("file:///tmp/x"), "invalid_request");
  throwsCode(() => normalizeDomain("https://person:secret@google.com"), "invalid_request");
});
test("accepts the exact username and a true website subdomain", () => {
  const result = credentialsFrom({ STATUS: 0, Entries: [fixture("person@example.test", ["https://accounts.google.com"])] }, "google.com", "person@example.test");
  assert(result.length === 1 && result[0].username === "person@example.test");
});
test("rejects a username prefix and lookalike website domains", () => {
  throwsCode(() => credentialsFrom({ STATUS: 0, Entries: [
    fixture("person@example.test.extra", ["google.com"]),
    fixture("person@example.test", ["google.com.attacker.test"]),
    fixture("person@example.test", ["notgoogle.com"]),
  ] }, "google.com", "person@example.test"), "not_found");
});
test("does not return a password placeholder", () => {
  throwsCode(() => credentialsFrom({ STATUS: 0, Entries: [fixture("p", ["google.com"], "Not Included")] }, "google.com", "p"), "not_found");
});
test("handles native numbered entries and folds identical password values", () => {
  const result = credentialsFrom({ STATUS: 0, Entry_2: fixture("p", ["google.com"]), Entry_1: fixture("p", ["accounts.google.com"]) }, "google.com", "p");
  assert(result.length === 2 && onePassword(result) === "fixture-secret");
});
test("keeps different matching passwords ambiguous for raw output", () => {
  const result = credentialsFrom({ STATUS: 0, Entries: [fixture("p", ["google.com"], "one"), fixture("p", ["accounts.google.com"], "two")] }, "google.com", "p");
  assert(result.length === 2);
  throwsCode(() => onePassword(result), "ambiguous");
});
test("preserves native locked and no-result states", () => {
  throwsCode(() => credentialsFrom({ STATUS: 9 }, "google.com", "p"), "locked");
  throwsCode(() => credentialsFrom({ STATUS: 3 }, "google.com", "p"), "not_found");
});

})();
