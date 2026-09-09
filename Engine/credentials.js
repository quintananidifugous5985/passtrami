(() => {
// SPDX-License-Identifier: GPL-3.0-or-later
// Message shape adapted from APW 1.1.1, src/client.ts.
class RequestError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function normalizeDomain(value) {
  if (typeof value !== "string" || !value.trim()) throw new RequestError("invalid_request", "Domain is required.");
  const host = __hostname(value);
  if (!host) throw new RequestError("invalid_request", "Use a website domain or an HTTP(S) URL.");
  return host;
}

function passwordMessage(domain, username) {
  return { cmd: 5, qid: "CmdGetPassword4LoginName", tabId: 0, frameId: 0, url: domain,
    body: { ACT: 2, URL: domain, USR: username } };
}

function accountsMessage(domain) {
  return { cmd: 4, qid: "CmdGetLoginNames4URL", tabId: 1, frameId: 1, url: domain,
    body: { ACT: 5, URL: domain } };
}



function entriesFrom(data) {
  if (data.STATUS === 3) return [];
  if (data.STATUS !== 0) throw new RequestError(data.STATUS === 9 ? "locked" : "native_error",
    data.STATUS === 9 ? "The password session is locked." : `Apple's helper returned status ${data.STATUS}.`);
  return Array.isArray(data.Entries) ? data.Entries : Object.entries(data)
    .filter(([key]) => key.startsWith("Entry_"))
    .sort(([a], [b]) => a.localeCompare(b, undefined, { numeric: true })).map(([, value]) => value);
}

function sitesFrom(entry) {
  return Array.isArray(entry.sites) ? entry.sites.filter((site) => typeof site === "string") : [];
}

function matchesDomain(sites, domain) {
  return sites.some((site) => {
    try { const host = normalizeDomain(site); return host === domain || host.endsWith(`.${domain}`); }
    catch { return false; }
  });
}

function usernamesFrom(data, domain) {
  const usernames = new Set();
  for (const entry of entriesFrom(data)) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry;
    if (typeof e.USR !== "string" || !e.USR || e.USR === "Passwords\u00a0not\u00a0saved") continue;
    const sites = sitesFrom(e);
    if (!matchesDomain(sites, domain)) continue;
    usernames.add(e.USR);
  }
  return [...usernames];
}

function credentialsFrom(data, domain, username) {
  if (data.STATUS === 3) throw new RequestError("not_found", "No matching password was found.");
  const result = [];
  for (const entry of entriesFrom(data)) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry;
    if (e.USR !== username || typeof e.PWD !== "string" || !e.PWD || e.PWD === "Not Included") continue;
    const sites = sitesFrom(e);
    if (matchesDomain(sites, domain)) result.push({ username, password: e.PWD, sites });
  }
  if (!result.length) throw new RequestError("not_found", "No password matched both the domain and username.");
  return result;
}

function onePassword(entries) {
  const passwords = new Set(entries.map((e) => e.password));
  if (passwords.size !== 1) throw new RequestError("ambiguous", "Multiple matching accounts have different passwords.");
  return entries[0].password;
}

globalThis.AsterCredentials = { RequestError, normalizeDomain, passwordMessage, accountsMessage, usernamesFrom, credentialsFrom, onePassword };
})();
