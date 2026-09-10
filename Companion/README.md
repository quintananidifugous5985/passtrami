# Companion module

Compile these Swift files into the Mac and iPhone apps. The engine does not use CloudKit.

Both apps use `iCloud.io.zats.Passtrami`, the same Apple Account, and the private `PasstramiCompanion` record zone. Enable iCloud/CloudKit and push notifications. The Mac registers for silent zone-change notifications while signed in; call `remoteChanged()` when one arrives. The iPhone requests alert permission and subscribes to approval requests after pairing. Approval pushes set mutable content so the bundled notification service extension can mark them Time Sensitive before display. The iPhone target includes the Time Sensitive entitlement. No APNs provider key is shipped.

The schema is in [schema.ckdb](schema.ckdb). Debug builds use Development; Release builds use Production. Import the schema in CloudKit Console and deploy it before distributing the apps.

| Record type | Fields | Indexes |
| --- | --- | --- |
| `PasstramiPair` | `pairID`, `state`, `lastOperation` (String); `offer`, `phone`, `proof` (Bytes); `expiresAt` (Date/Time) | None |
| `PasstramiRequest` | `pairID`, `requestID`, `status` (String); `request`, `response` (Bytes); `createdAt`, `decisionAt`, `consumedAt` (Date/Time) | `pairID` Queryable; `status` Queryable; `createdAt` Sortable |

The fixed pairing record prevents a second Mac or phone from replacing an active pair. A five-minute, 12-character code binds the phone key to the Mac offer with HMAC-SHA256. The request includes the exact website, account, device IDs, pair ID, random request ID, and expiry. The Mac signs it. A deliberate approval uses the iPhone's Secure Enclave key with Keychain `userPresence`, then signs the exact request digest. A decline needs no authentication and can only reject a request. The Mac validates the response and atomically checks the current pair and marks the approval used before it returns. CloudKit records never contain passwords.

Call `start()` while the service should refresh, and `stop()` when the app stops or the phone enters the background. Refresh when the phone returns to the foreground or opens a notification. `CompanionService.notificationCategory` is `passtrami.approval`. `CKQueryNotification.recordID.recordName` and `recordFields["requestID"]` contain the request ID. Push delivery is not guaranteed; fetch the current records before showing or acting on a request. Approve actions must open the foreground app before calling `approve`; Decline can run in a notification response handler.

`requestApproval` throws on denied, expired, cancelled, unpaired, unverifiable, or unreachable requests. `hasLocalPairing` remains true when iCloud becomes unavailable; callers must not treat account failure as an unpaired device. A newly trusted Mac pairing sets `useIPhoneApproval` to true before it publishes the pair. The UI methods set `errorMessage` rather than throw.

Pure protocol checks (no CloudKit, account access, passwords, or authentication prompts):

```sh
xcrun swiftc -swift-version 6 -strict-concurrency=complete Companion/CompanionModels.swift Tests/Companion/main.swift -o /tmp/passtrami-companion-checks
/tmp/passtrami-companion-checks
```

These checks do not prove CloudKit delivery or a physical iPhone's authentication. Those need signed builds, the schema in the selected environment, and a device test.

After phone approval, the engine guard briefly disables the shared `TouchIDToAutoFill` setting, then restores its previous value before returning a password. The guard restores on pipe closure, engine exit, or its one-second deadline. Another paired browser can still read the disabled setting during that interval. Scheduling, preference writes, and propagation prevent a strict one-second system-wide guarantee. The guard does not isolate this request from other browsers.
