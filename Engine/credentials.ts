// SPDX-License-Identifier: GPL-3.0-or-later
// Message shape adapted from APW 1.1.1, src/client.ts.
export class RequestError extends Error {
  constructor(public code: string, message: string) { super(message); }
}

export function normalizeDomain(value: unknown): string {
  if (typeof value !== "string" || !value.trim()) throw new RequestError("invalid_request", "Domain is required.");
  try {
    const url = new URL(value.includes("://") ? value : `https://${value}`);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || !url.hostname) throw 0;
    return url.hostname.toLowerCase().replace(/\.$/, "");
  } catch { throw new RequestError("invalid_request", "Use a website domain or an HTTP(S) URL."); }
}

export function passwordMessage(domain: string, username: string) {
  return { cmd: 5, qid: "CmdGetPassword4LoginName", tabId: 0, frameId: 0, url: domain,
    body: { ACT: 2, URL: domain, USR: username } };
}

export function accountsMessage(domain: string) {
  return { cmd: 4, qid: "CmdGetLoginNames4URL", tabId: 1, frameId: 1, url: domain,
    body: { ACT: 5, URL: domain } };
}

export interface Credential { username: string; password: string; sites: string[]; }

function entriesFrom(data: Record<string, unknown>): unknown[] {
  if (data.STATUS === 3) return [];
  if (data.STATUS !== 0) throw new RequestError(data.STATUS === 9 ? "locked" : "native_error",
    data.STATUS === 9 ? "The password session is locked." : `Apple's helper returned status ${data.STATUS}.`);
  return Array.isArray(data.Entries) ? data.Entries : Object.entries(data)
    .filter(([key]) => key.startsWith("Entry_"))
    .sort(([a], [b]) => a.localeCompare(b, undefined, { numeric: true })).map(([, value]) => value);
}

function sitesFrom(entry: Record<string, unknown>): string[] {
  return Array.isArray(entry.sites) ? entry.sites.filter((site): site is string => typeof site === "string") : [];
}

function matchesDomain(sites: string[], domain: string): boolean {
  return sites.some((site) => {
    try { const host = normalizeDomain(site); return host === domain || host.endsWith(`.${domain}`); }
    catch { return false; }
  });
}

export function usernamesFrom(data: Record<string, unknown>, domain: string): string[] {
  const usernames = new Set<string>();
  for (const entry of entriesFrom(data)) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    if (typeof e.USR !== "string" || !e.USR || e.USR === "Passwords\u00a0not\u00a0saved") continue;
    const sites = sitesFrom(e);
    if (!matchesDomain(sites, domain)) continue;
    usernames.add(e.USR);
  }
  return [...usernames];
}

export function credentialsFrom(data: Record<string, unknown>, domain: string, username: string): Credential[] {
  if (data.STATUS === 3) throw new RequestError("not_found", "No matching password was found.");
  const result: Credential[] = [];
  for (const entry of entriesFrom(data)) {
    if (!entry || typeof entry !== "object") continue;
    const e = entry as Record<string, unknown>;
    if (e.USR !== username || typeof e.PWD !== "string" || !e.PWD || e.PWD === "Not Included") continue;
    const sites = sitesFrom(e);
    if (matchesDomain(sites, domain)) result.push({ username, password: e.PWD, sites });
  }
  if (!result.length) throw new RequestError("not_found", "No password matched both the domain and username.");
  return result;
}

export function onePassword(entries: Credential[]): string {
  const passwords = new Set(entries.map((e) => e.password));
  if (passwords.size !== 1) throw new RequestError("ambiguous", "Multiple matching accounts have different passwords.");
  return entries[0].password;
}
