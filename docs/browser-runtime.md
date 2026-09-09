# Browser runtime

Aster uses a pinned, signed Ungoogled Chromium release on Apple silicon. It stores the browser at `~/Library/Application Support/io.zats.Aster/Browser/152.0.7977.82-1.1/Chromium.app`.

If the cached browser is missing or fails verification, Aster downloads the pinned [upstream release](https://github.com/ungoogled-software/ungoogled-chromium-macos/releases/tag/152.0.7977.82-1.1). The app bundle does not contain Chromium.

| Check | Required value |
| --- | --- |
| Architecture | `arm64` |
| Signing identifier | `io.ungoogled-software.ungoogled-chromium` |
| Developer team | `B9A88FL5XJ` |
| Browser version | Exactly `152.0.7977.82` |
| Download release | `152.0.7977.82-1.1` |
| DMG SHA256 | `ba673876533e79b3c09edaf3ebd0dadcc29e9d0112b9b843d8c032cfb7bfb457` |

The URL, hash, version, and signing requirement are set in [`EngineHost/Browser/BrowserRuntime.swift`](../EngineHost/Browser/BrowserRuntime.swift). Both cached and newly downloaded copies must pass strict code-signature verification and Gatekeeper assessment. Apple's native helper also enforces its own browser launch constraints; a generic Chromium build is not interchangeable with this signed release.

## Setup

Aster verifies the downloaded bytes, mounts the image read-only, copies the app to a temporary folder, verifies it, then moves it into the cache. It removes FinderInfo metadata from the copy. It preserves the vendor signature and quarantine metadata. Startup uses system tools and does not require Xcode.

The menu bar icon's tooltip shows setup progress. **Cancel Setup** stops the operation, ejects any mounted image, and removes temporary files. A download has a ten-minute limit. A failed system check reports its operation, tool, and exit status in the tooltip and `aster status`, without command output or file paths. Use **Unlock…** to try again.

## Browser session

Each session uses a temporary profile and extension copy. Aster loads the extension through [`Extensions.loadUnpacked`](https://chromedevtools.github.io/devtools-protocol/tot/Extensions/#method-loadUnpacked), then closes the DevTools connection. The full browser runs in headless mode.

The launch flags in [`EngineHost/Browser/BrowserSession.swift`](../EngineHost/Browser/BrowserSession.swift) disable website and native notifications, DIAL discovery, and the browser's app-copy step for updates. `--use-mock-keychain` prevents a Chromium Safe Storage prompt for the temporary profile. These settings do not replace Apple's password authentication.

## Notices

[`Resources/Notices`](../Resources/Notices) contains the [Ungoogled Chromium license](https://github.com/ungoogled-software/ungoogled-chromium-macos/blob/152.0.7977.82-1.1/LICENSE), the [matching Chromium license](https://github.com/chromium/chromium/blob/152.0.7977.82/LICENSE), and third-party notices from the pinned browser's `chrome://credits` page.
