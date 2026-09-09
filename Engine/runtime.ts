// SPDX-License-Identifier: GPL-3.0-or-later
import { createHash } from "node:crypto";
import { RequestError } from "./credentials.ts";

const release = "152.0.7977.82-1.1";
const minimumVersion = "152.0.7977.82";
const archiveURL = `https://github.com/ungoogled-software/ungoogled-chromium-macos/releases/download/${release}/ungoogled-chromium_${release}_arm64-macos.dmg`;
const archiveSHA256 = "ba673876533e79b3c09edaf3ebd0dadcc29e9d0112b9b843d8c032cfb7bfb457";
const signingRequirement = '=anchor apple generic and identifier "io.ungoogled-software.ungoogled-chromium" and certificate leaf[subject.OU] = "B9A88FL5XJ"';
type Progress = (message: string) => void;

function cancelled(): RequestError {
  return new RequestError("cancelled", "Browser setup was cancelled.");
}

function checkCancelled(signal: AbortSignal): void {
  if (signal.aborted) throw cancelled();
}

export function isCompatibleVersion(version: string): boolean {
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(version)) return false;
  const actual = version.split(".").map(Number);
  if (actual.some((part) => !Number.isSafeInteger(part))) return false;
  const required = minimumVersion.split(".").map(Number);
  for (let index = 0; index < required.length; index++) {
    if (actual[index] !== required[index]) return actual[index] > required[index];
  }
  return true;
}

export async function runSystemCheck(operation: string, command: string, args: string[], signal: AbortSignal, timeout = 30000): Promise<string> {
  checkCancelled(signal);
  const tool = command.slice(command.lastIndexOf("/") + 1);
  let child: Deno.ChildProcess;
  try {
    child = new Deno.Command(command, { args, stdin: "null", stdout: "piped", stderr: "piped" }).spawn();
  } catch {
    throw new RequestError("browser_setup", `${operation} could not start (${tool}).`);
  }
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  let timedOut = false;
  const stop = () => {
    try { child.kill("SIGTERM"); } catch { /* Already exited. */ }
    killTimer ??= setTimeout(() => {
      try { child.kill("SIGKILL"); } catch { /* Already exited. */ }
    }, 1000);
  };
  const timeoutTimer = setTimeout(() => { timedOut = true; stop(); }, timeout);
  signal.addEventListener("abort", stop, { once: true });
  if (signal.aborted) stop();
  try {
    const result = await child.output();
    checkCancelled(signal);
    if (timedOut) throw new RequestError("browser_setup", `${operation} timed out (${tool}).`);
    if (!result.success) {
      const reason = result.signal ? `signal ${result.signal}` : `exit ${result.code}`;
      throw new RequestError("browser_verify", `${operation} failed (${tool}, ${reason}).`);
    }
    return new TextDecoder().decode(result.stdout).trim();
  } finally {
    clearTimeout(timeoutTimer);
    clearTimeout(killTimer);
    signal.removeEventListener("abort", stop);
  }
}

async function exists(path: string): Promise<boolean> {
  try { await Deno.stat(path); return true; }
  catch (error) { if (error instanceof Deno.errors.NotFound) return false; throw error; }
}

async function validateBrowser(app: string, signal: AbortSignal, pinned = false): Promise<string> {
  checkCancelled(signal);
  const executable = `${app}/Contents/MacOS/Chromium`;
  const info = await Deno.stat(executable);
  if (!info.isFile || !((info.mode ?? 0) & 0o111)) {
    throw new RequestError("browser_verify", "The Chromium executable is missing.");
  }
  const version = await runSystemCheck("Chromium version check", "/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", `${app}/Contents/Info.plist`], signal);
  if (!isCompatibleVersion(version) || (pinned && version !== minimumVersion)) {
    throw new RequestError("browser_version", "This Chromium version is not supported.");
  }
  await runSystemCheck("Chromium architecture check", "/usr/bin/codesign", ["--display", "--architecture", "arm64", executable], signal);
  // Test the signed identity, certificate, and sealed bundle together. Keep the vendor signature.
  await runSystemCheck("Chromium signature check", "/usr/bin/codesign", ["--verify", "--deep", "--strict", "--test-requirement", signingRequirement, app], signal);
  await runSystemCheck("Chromium Gatekeeper check", "/usr/sbin/spctl", ["--assess", "--type", "exec", app], signal, 60000);
  return executable;
}

// The archive is usable only after the streamed bytes pass the pinned checksum.
// On failure, this function removes only the file that it created.
export async function downloadArchive(url: string, destination: string, expectedSHA256: string, signal: AbortSignal, onProgress: Progress): Promise<void> {
  checkCancelled(signal);
  const transfer = new AbortController();
  let timedOut = false;
  const abort = () => transfer.abort();
  signal.addEventListener("abort", abort, { once: true });
  if (signal.aborted) abort();
  const timeoutTimer = setTimeout(() => { timedOut = true; transfer.abort(); }, 600000);
  let file: Deno.FsFile | undefined;
  let response: Response | undefined;
  let complete = false;
  let created = false;
  try {
    response = await fetch(url, { signal: transfer.signal, redirect: "follow" });
    if (!response.ok || !response.body) throw new RequestError("browser_download", "Chromium could not be downloaded. Try Unlock again.");
    file = await Deno.open(destination, { write: true, createNew: true, mode: 0o600 });
    created = true;
    const hash = createHash("sha256");
    const length = Number(response.headers.get("content-length")) || 0;
    let received = 0, lastProgress = 0;
    for await (const chunk of response.body) {
      checkCancelled(transfer.signal);
      hash.update(chunk);
      let offset = 0;
      while (offset < chunk.byteLength) offset += await file.write(chunk.subarray(offset));
      received += chunk.byteLength;
      const now = Date.now();
      if (now - lastProgress >= 1000) {
        const amount = length > 0 ? `${Math.min(100, Math.floor(received / length * 100))}%` : `${Math.floor(received / 1048576)} MB`;
        onProgress(`Downloading Chromium: ${amount}`);
        lastProgress = now;
      }
    }
    checkCancelled(transfer.signal);
    if (hash.digest("hex") !== expectedSHA256) throw new RequestError("browser_checksum", "The Chromium download failed its checksum check. Try Unlock again.");
    await file.sync();
    checkCancelled(transfer.signal);
    complete = true;
  } catch (error) {
    if (signal.aborted) throw cancelled();
    if (timedOut) throw new RequestError("browser_download", "The Chromium download took too long. Try Unlock again.");
    if (error instanceof RequestError || error instanceof Deno.errors.AlreadyExists) throw error;
    throw new RequestError("browser_download", "Chromium could not be downloaded. Check your connection, then try Unlock again.");
  } finally {
    clearTimeout(timeoutTimer);
    signal.removeEventListener("abort", abort);
    file?.close();
    if (response?.body && !response.body.locked) await response.body.cancel().catch(() => {});
    if (created && !complete) await Deno.remove(destination).catch(() => {});
  }
}

async function detachImage(mount: string): Promise<void> {
  const cleanupSignal = new AbortController().signal;
  try {
    await runSystemCheck("Chromium disk image eject", "/usr/sbin/diskutil", ["eject", mount], cleanupSignal, 10000);
  } catch {
    // An aborted attach might never have mounted the image.
    if (!await exists(`${mount}/Chromium.app`)) return;
    await runSystemCheck("Chromium disk image detach", "/usr/bin/hdiutil", ["detach", "-force", mount], cleanupSignal, 10000);
  }
}

export async function resolveBrowser(dataDir: string, signal: AbortSignal, onProgress: Progress): Promise<string> {
  checkCancelled(signal);
  if (Deno.build.os !== "darwin" || Deno.build.arch !== "aarch64") {
    throw new RequestError("browser_platform", "Aster requires an Apple silicon Mac.");
  }
  const userHome = Deno.env.get("HOME");
  const installed = ["/Applications/Chromium.app", ...(userHome ? [`${userHome}/Applications/Chromium.app`] : [])];
  for (const app of installed) {
    try {
      if (!await exists(app)) continue;
      onProgress("Checking installed Chromium…");
      return await validateBrowser(app, signal);
    }
    catch { checkCancelled(signal); }
  }
  const cache = `${dataDir}/Browser`;
  const versionDirectory = `${cache}/${release}`;
  const cachedApp = `${versionDirectory}/Chromium.app`;
  if (await exists(cachedApp)) {
    onProgress("Checking Chromium…");
    try { return await validateBrowser(cachedApp, signal, true); }
    catch { checkCancelled(signal); }
  }
  checkCancelled(signal);
  await Deno.mkdir(cache, { recursive: true, mode: 0o700 });
  await Deno.chmod(cache, 0o700);
  const staging = await Deno.makeTempDir({ dir: cache, prefix: "download-" });
  const mount = `${staging}/mount`, packageDirectory = `${staging}/package`;
  let attachStarted = false;
  try {
    await Deno.chmod(staging, 0o700);
    onProgress("Downloading Chromium…");
    const archive = `${staging}/browser.dmg`;
    await downloadArchive(archiveURL, archive, archiveSHA256, signal, onProgress);
    checkCancelled(signal);
    onProgress("Installing Chromium…");
    await Deno.mkdir(mount, { mode: 0o700 });
    await Deno.mkdir(packageDirectory, { mode: 0o700 });
    attachStarted = true;
    await runSystemCheck("Chromium disk image mount", "/usr/sbin/diskutil", ["image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mount, archive], signal, 60000);
    await runSystemCheck("Chromium copy", "/usr/bin/ditto", [`${mount}/Chromium.app`, `${packageDirectory}/Chromium.app`], signal, 120000);
    await detachImage(mount);
    attachStarted = false;
    checkCancelled(signal);
    // FinderInfo from the HFS image is outside the code seal. Do not remove quarantine or re-sign.
    await runSystemCheck("Chromium Finder metadata cleanup", "/usr/bin/xattr", ["-dr", "com.apple.FinderInfo", `${packageDirectory}/Chromium.app`], signal);
    onProgress("Checking Chromium…");
    await validateBrowser(`${packageDirectory}/Chromium.app`, signal, true);
    checkCancelled(signal);
    if (await exists(versionDirectory)) await Deno.remove(versionDirectory, { recursive: true });
    checkCancelled(signal);
    await Deno.rename(packageDirectory, versionDirectory);
    return `${cachedApp}/Contents/MacOS/Chromium`;
  } finally {
    // Do not delete a staging directory while a disk image is still mounted inside it.
    if (attachStarted) await detachImage(mount);
    await Deno.remove(staging, { recursive: true });
  }
}
