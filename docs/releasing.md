# Release Passtrami

The release ZIP is hosted on [GitHub Releases](https://github.com/zats/passtrami/releases). GitHub Pages hosts [appcast.xml](https://zats.io/passtrami/appcast.xml). Publishing a stable release starts the feed deployment; no separate website upload is needed. The feed contains the current stable Apple silicon release for macOS 26.2 or later.

## One-time setup

- Install a Developer ID Application identity for the Apple Developer team on the release Mac. Create and download a **Developer ID** provisioning profile for `io.zats.Passtrami` with CloudKit, the `iCloud.io.zats.Passtrami` container, and production push notifications. The profile must allow Production CloudKit and use the release signing certificate. A Mac development profile is not sufficient.
- Deploy the [companion record schema and indexes](../Companion/README.md) to the CloudKit Production environment before distributing the companion feature.
- Store notarization credentials with `xcrun notarytool store-credentials PROFILE`. Use the interactive prompts; do not put passwords in scripts or commit them.
- Run `python3 scripts/sparkle-tools.py generate_keys --account io.zats.Passtrami`. The public key must match `SUPublicEDKey` in `Info.plist`. Keep the private key in the Keychain. Do not replace it for each release or export it to GitHub Actions.
- In the repository's **Settings → Pages**, select **GitHub Actions** as the source and enforce HTTPS. In the `github-pages` environment, permit the `main` branch and tags matching `v*b*`. Release events run from a tag. This account's Pages site uses the `zats.io` domain.

The tools runner pins Sparkle's version, Git revision, and SHA256 checksum in `scripts/sparkle-tools.py`. The repository, version, and revision must match `Package.resolved`. Update both pins together when upgrading Sparkle, using the checksum from the official manifest linked in the script. The runner uses the same ZIP as Swift Package Manager. Each invocation checks the archive, including cached copies, extracts fresh tools, runs the selected tool, and removes the extracted files. A pin or checksum mismatch stops the release before a tool runs; cached Git objects and manifests cannot change the trusted checksum.

## Prepare a release

Increase `CFBundleVersion` in `Info.plist` for every release. Set `CFBundleShortVersionString` to the visible version. Write the release notes in a Markdown file. Commit the source changes before the release build.

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
TEAM_ID='TEAMID' \
DEVELOPER_ID_PROFILE='/path/to/Passtrami.provisionprofile' \
./scripts/prepare-release.sh /path/to/notes.md PROFILE
```

The script first checks and installs the supplied provisioning profile. A missing, expired, or mismatched profile stops preparation before tests or archiving. It prepares the pinned Apple extension, runs the tests, archives the Mac app and its helpers, and exports a Developer ID app with that profile and Production CloudKit access. Helpers do not receive the app's profile. It requires accepted notarization, staples and validates the ticket, creates the final ZIP, and uses Sparkle's `generate_appcast` to sign it and embed the release notes. It also verifies the archive signature with Sparkle. Any failed step stops the release.

Output is `build/Distribution/vVERSIONbBUILD/`: the app, versioned ZIP, an identical `Passtrami.zip` copy, checksum, `appcast.xml`, notarization result, and source commit. Existing output is never overwritten. The script does not create tags, push source, or publish a release.

## Publish

After the app and update have passed testing, create and push a tag for the recorded source commit. Use a new version and build for each published archive. Do not replace assets for an existing release.

```sh
git tag -a vVERSIONbBUILD -m 'Passtrami VERSION (BUILD)'
git push origin main vVERSIONbBUILD
gh release create vVERSIONbBUILD --repo zats/passtrami --verify-tag \
  --title 'Passtrami VERSION (BUILD)' --notes-file /path/to/notes.md \
  build/Distribution/vVERSIONbBUILD/Passtrami-VERSION-bBUILD-macOS-arm64.zip \
  build/Distribution/vVERSIONbBUILD/Passtrami-VERSION-bBUILD-macOS-arm64.zip.sha256 \
  build/Distribution/vVERSIONbBUILD/Passtrami.zip \
  build/Distribution/vVERSIONbBUILD/appcast.xml
```

Upload `Passtrami.zip` with every release. The README uses [GitHub’s stable direct-download URL](https://github.com/zats/passtrami/releases/latest/download/Passtrami.zip), which selects that asset from the latest release. Sparkle continues to use the versioned ZIP.

The **Publish update feed** workflow gets the latest stable release, checks the feed's version, download URL, size, and signature format against the release asset, then deploys `appcast.xml` with GitHub's Pages actions. It never deploys a prerelease. Manual workflow runs also select the latest stable release. Cryptographic archive verification occurs during local preparation and again in the installed app.

Wait for the Pages workflow to finish. Open the public appcast and check its version and download URL. In an older installed app, use **Check for Updates…**, install the update, and check the installed version. A successful upload alone does not prove that the app can update.

The initial ad-hoc builds need a manual installation of the first distributed build. Later builds use the stable Sparkle public key, bundle identifier, and feed URL.

References: [Sparkle publishing](https://sparkle-project.org/documentation/publishing/), [GitHub Pages custom workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
