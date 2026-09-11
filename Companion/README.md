# Companion module

Compile these Swift files into the Mac and iPhone apps. The engine does not use CloudKit.

Both apps use `iCloud.io.zats.Passtrami`, the same Apple Account, and the private `PasstramiCompanion` record zone. Enable iCloud/CloudKit and push notifications. The Mac registers for silent zone-change notifications while signed in; call `remoteChanged()` when one arrives. The iPhone requests alert permission and subscribes to approval requests after pairing. Approval pushes set mutable content so the bundled notification service extension can mark them Time Sensitive before display. The iPhone target includes the Time Sensitive entitlement. No APNs provider key is shipped.

The schema is in [schema.ckdb](schema.ckdb). Debug builds use Development; Release builds use Production. Import the schema in CloudKit Console and deploy it before distributing the apps.

| Record type | Fields | Indexes |
| --- | --- | --- |
| `PasstramiPair` | `pairID`, `state`, `lastOperation` (String); `offer`, `phone`, `proof` (Bytes); `expiresAt` (Date/Time) | None |
| `PasstramiRequest` | `pairID`, `requestID`, `status` (String); `request`, `response` (Bytes); `createdAt`, `decisionAt`, `consumedAt` (Date/Time) | `pairID` Queryable; `status` Queryable; `createdAt` Sortable |

The fixed pairing record prevents a second Mac or phone from replacing an active pair. A five-minute, 12-character code authenticates the complete Mac offer with HMAC-SHA256: purpose, version, pair ID, Mac identity and key, and expiry. The phone verifies this before it saves trust, then returns a code-authenticated receipt binding both devices. QR scanning and manual code entry use the same verification. The existing `offer` Bytes field contains this authenticated envelope. Unpair in the previous apps before installing these builds, then pair again. These builds reject unsigned offers and cannot remove old-format pairing records.

Requests include the exact website, account, device IDs, pair ID, random request ID, and expiry. The Mac signs each request. A deliberate approval uses the iPhone's Secure Enclave key with Keychain `userPresence`, then signs the exact request digest. A decline needs no authentication and can only reject a request. The Mac validates the response and atomically checks the current pair and marks the approval used before it returns. CloudKit records never contain passwords.

Call `start()` while the service should refresh, and `stop()` when the app stops or the phone enters the background. Refresh when the phone returns to the foreground or opens a notification. `CompanionService.notificationCategory` is `passtrami.approval`. `CKQueryNotification.recordID.recordName` and `recordFields["requestID"]` contain the request ID. Push delivery is not guaranteed; fetch the current records before showing or acting on a request. Approve actions must open the foreground app before calling `approve`; Decline can run in a notification response handler.

The Mac routes password access through `authorizePasswordAccess` and reads its policy from the app's Data Protection Keychain access group. Normal Apple approval is selected only by a stored local-approval value. Missing or unreadable storage blocks password access. On launch, the Mac checks access to the protected Apple Passwords preferences before starting the engine or downloading Chromium. If access is denied, General settings explains the required Full Disk Access permission and opens its System Settings pane. In Devices settings, pairing enables required phone approval, or **Use Local Approval…** authenticates on the Mac before saving local approval. UserDefaults values are not used or migrated.

With phone approval required, denied, expired, cancelled, unpaired, unverifiable, and unreachable requests fail. CloudKit changes and unpairing never disable the policy. Only an explicit Mac action with local authentication can turn it off, including when iCloud is unavailable. A newly trusted Mac pairing must save the protected requirement before it activates trust. The Mac sends the policy to the engine at startup and on changes. The UI methods set `errorMessage` rather than throw.

Pure protocol checks (no CloudKit, account access, passwords, or authentication prompts):

```sh
Tests/Companion/run.sh
```

These checks do not prove CloudKit delivery or a physical iPhone's authentication. Those need signed builds, the schema in the selected environment, and a device test.

Phone-required mode requires Touch ID for AutoFill to be enabled before access. After phone approval, the engine guard briefly disables the shared `TouchIDToAutoFill` setting, then enables protection before returning a password, including cleanup after an error. It restores protection on pipe closure, engine exit, or its one-second deadline; recovery markers cannot specify a weaker value. Another paired browser can still read the disabled setting during that interval. Scheduling, preference writes, and propagation prevent a strict one-second system-wide guarantee. The guard does not isolate this request from other browsers.
