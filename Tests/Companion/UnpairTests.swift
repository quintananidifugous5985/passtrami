import CloudKit
import Foundation

@main @MainActor
struct UnpairTests {
    static let mac = CompanionDevice(id: "test-mac", name: "Test Mac", role: .mac, publicKey: Data("mac-key".utf8))
    static let phone = CompanionDevice(id: "test-phone", name: "Test Phone", role: .phone, publicKey: Data("phone-key".utf8))
    static let trust = CompanionTrust(accountID: "test-account", pairID: "old-pair", mac: mac, phone: phone)
    static var policy = TestApprovalPolicyStore()

    static func makeService(role: CompanionRole, defaults: UserDefaults,
        authenticatePolicyChange: @escaping @MainActor () async throws -> Void = {
            preconditionFailure("This test must not request local authentication")
        }) -> CompanionService {
        CompanionService(role: role, defaults: defaults, policyStore: policy.store,
            authenticatePolicyChange: authenticatePolicyChange)
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func withDefaults(_ operation: (UserDefaults) async throws -> Void) async throws {
        let suite = "io.zats.Passtrami.tests.unpair.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(mac.id, forKey: "companion.deviceID.mac")
        defaults.set(phone.id, forKey: "companion.deviceID.phone")
        CompanionCloudStore.reset()
        policy = TestApprovalPolicyStore()
        try await operation(defaults)
    }

    static func pairRecord(pairID: String = "old-pair", mac: CompanionDevice = mac,
                           phone: CompanionDevice = phone) throws -> CKRecord {
        let offer = CompanionPairingOffer(pairID: pairID, mac: mac,
            expiresAt: Date().addingTimeInterval(300))
        let record = CKRecord(recordType: "PasstramiPair", recordID: CompanionCloudStore.pairRecordID)
        record["pairID"] = pairID
        record["state"] = "paired"
        record["offer"] = try CompanionProtocol.encode(CompanionProtocol.authenticateOffer(offer, code: "ABCDEFGHJKMN"))
        record["phone"] = try CompanionProtocol.encode(phone)
        return record
    }

    static func saveTrust(_ defaults: UserDefaults) throws {
        defaults.set(try CompanionProtocol.encode(trust), forKey: "companion.trust")
    }

    static func makeOffer(_ defaults: UserDefaults) async throws -> CKRecord {
        let service = makeService(role: .mac, defaults: defaults)
        await service.beginPairing()
        expect(service.errorMessage == nil, "The test Mac must create its offer")
        let record = CompanionCloudStore.pair!
        expect(defaults.string(forKey: "companion.offerPairID") == record["pairID"] as? String,
               "The locally issued offer ID must be saved")
        expect(defaults.string(forKey: "companion.offerAccountID") == "test-account",
               "The pending offer must retain its account")
        CompanionCloudStore.saveCount = 0
        return record
    }

    static func claimOffer(_ record: CKRecord, defaults: UserDefaults, validProof: Bool = true) throws {
        let offer = try CompanionProtocol.decode(CompanionAuthenticatedOffer.self, from: record["offer"] as! Data).offer
        let code = defaults.string(forKey: "companion.offerCode")!
        record["state"] = "paired"
        record["phone"] = try CompanionProtocol.encode(phone)
        record["proof"] = validProof ? try CompanionProtocol.pairingProof(code: code,
            receipt: CompanionPairingReceipt(pairID: offer.pairID, mac: offer.mac, phone: phone)) : Data("invalid".utf8)
    }

    static func main() async throws {
        try await withDefaults { defaults in
            try saveTrust(defaults)
            CompanionCloudStore.pair = try pairRecord()
            let service = makeService(role: .phone, defaults: defaults)
            await service.unpair()
            expect(CompanionCloudStore.pair?["state"] as? String == "revoked", "Unpair must revoke the current pair")
            expect(!service.hasLocalPairing && service.errorMessage == nil, "Successful unpair must clear local trust")
            expect(CompanionCloudStore.removedPairs == [trust.pairID], "Delete only the captured pair subscription")
            expect(CompanionCloudStore.subscriptions == ["phone-approvals-new-pair", "mac-companion-zone"],
                   "Other subscriptions must survive")
        }

        for changed in ["pair ID", "Mac key", "Mac name", "phone key", "phone ID", "record pair ID"] {
            try await withDefaults { defaults in
                try saveTrust(defaults)
                var cloudMac = mac
                var cloudPhone = phone
                if changed == "Mac key" || changed == "Mac name" {
                    cloudMac = CompanionDevice(id: mac.id, name: changed == "Mac name" ? "Another Mac" : mac.name,
                        role: .mac, publicKey: changed == "Mac key" ? Data("another-key".utf8) : mac.publicKey)
                }
                if changed == "phone key" || changed == "phone ID" {
                    cloudPhone = CompanionDevice(id: changed == "phone ID" ? "another-phone" : phone.id,
                        name: phone.name, role: .phone,
                        publicKey: changed == "phone key" ? Data("another-key".utf8) : phone.publicKey)
                }
                let record = try pairRecord(pairID: changed == "pair ID" ? "new-pair" : trust.pairID,
                                            mac: cloudMac, phone: cloudPhone)
                if changed == "record pair ID" { record["pairID"] = "new-pair" }
                CompanionCloudStore.pair = record
                let service = makeService(role: .phone, defaults: defaults)
                await service.unpair()
                expect(CompanionCloudStore.saveCount == 0, "A changed \(changed) must prevent revocation")
                expect(CompanionCloudStore.pair?["state"] as? String == "paired", "The new pair must remain active")
                expect(!service.hasLocalPairing && service.errorMessage == nil, "Clear only stale local trust")
                expect(CompanionCloudStore.removedPairs == [trust.pairID], "Keep subscription removal bound to old trust")
            }
        }

        try await withDefaults { defaults in
            CompanionCloudStore.pair = try pairRecord()
            await makeService(role: .phone, defaults: defaults).unpair()
            expect(CompanionCloudStore.saveCount == 0 && CompanionCloudStore.removedPairs.isEmpty,
                   "An unpaired phone must not change another pair or its subscriptions")
        }

        try await withDefaults { defaults in
            _ = try await makeOffer(defaults)
            let restarted = makeService(role: .mac, defaults: defaults)
            await restarted.unpair()
            expect(CompanionCloudStore.pair?["state"] as? String == "revoked", "Cancel the own pending offer after restart")
            expect(restarted.pairingCode == nil && restarted.errorMessage == nil, "Clear the cancelled pairing code")
            expect(defaults.string(forKey: "companion.offerPairID") == nil, "Clear saved offer ownership")
        }

        try await withDefaults { defaults in
            _ = try await makeOffer(defaults)
            CompanionCloudStore.account = "different-account"
            let service = makeService(role: .mac, defaults: defaults)
            await service.unpair()
            expect(CompanionCloudStore.saveCount == 0, "An offer from another account must not authorize a cloud mutation")
            expect(service.errorMessage != nil && service.pairingCode != nil, "An account mismatch must retain the pending offer locally")
        }

        for changed in ["pair ID", "Mac ID", "Mac key", "authentication", "expiry"] {
            try await withDefaults { defaults in
                let record = try await makeOffer(defaults)
                let authenticated = try CompanionProtocol.decode(CompanionAuthenticatedOffer.self, from: record["offer"] as! Data)
                let offer = authenticated.offer
                let cloudMac = CompanionDevice(id: changed == "Mac ID" ? "other-mac" : offer.mac.id,
                    name: offer.mac.name, role: .mac,
                    publicKey: changed == "Mac key" ? Data("other-key".utf8) : offer.mac.publicKey)
                let changedOffer = CompanionPairingOffer(pairID: changed == "pair ID" ? "new-pair" : offer.pairID,
                    mac: cloudMac,
                    expiresAt: changed == "expiry" ? offer.expiresAt.addingTimeInterval(1) : offer.expiresAt)
                record["pairID"] = changedOffer.pairID
                record["offer"] = try CompanionProtocol.encode(CompanionAuthenticatedOffer(offer: changedOffer,
                    authentication: changed == "authentication" ? Data("invalid".utf8) : authenticated.authentication))
                await makeService(role: .mac, defaults: defaults).unpair()
                expect(CompanionCloudStore.saveCount == 0, "Cancel must not revoke a different offer: \(changed)")
                expect(CompanionCloudStore.pair?["state"] as? String == "offered", "Keep the unrelated offer")
            }
        }

        for validProof in [true, false] {
            try await withDefaults { defaults in
                let record = try await makeOffer(defaults)
                try claimOffer(record, defaults: defaults, validProof: validProof)
                let service = makeService(role: .mac, defaults: defaults)
                await service.unpair()
                expect(CompanionCloudStore.saveCount == (validProof ? 1 : 0),
                       "A just-claimed own offer requires a valid receipt before revocation")
                expect((service.errorMessage == nil) == validProof, "Invalid receipt must produce an error")
            }
        }

        try await withDefaults { defaults in
            try saveTrust(defaults)
            CompanionCloudStore.pair = try pairRecord()
            CompanionCloudStore.beforeSave = {
                CompanionCloudStore.pair = try pairRecord(pairID: "new-pair")
                throw CKError(.serverRecordChanged)
            }
            let service = makeService(role: .phone, defaults: defaults)
            await service.unpair()
            expect(service.hasLocalPairing && service.errorMessage != nil, "A save conflict must preserve retry state")
            expect(CompanionCloudStore.pair?["pairID"] as? String == "new-pair", "A conditional conflict must keep the new pair")
            expect(CompanionCloudStore.removedPairs.isEmpty, "Do not remove subscriptions after a failed save")
            await service.unpair()
            expect(!service.hasLocalPairing && service.errorMessage == nil, "Retry clears the stale local pair")
            expect(CompanionCloudStore.saveCount == 0, "Retry must not revoke the newer pair")
        }

        try await checkRefreshRace(changeAccount: false)
        try await checkRefreshRace(changeAccount: true)
        try await checkOfferRefreshRace()
        try await checkApprovalPolicy()
        try await checkAuthenticatedEnrollment()
        print("Companion unpair checks passed: pair/key ownership, scoped subscriptions, pending offers, claimed offers, conflicts, refresh races, and account changes")
    }

    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("The test operation did not reach its checkpoint")
    }

    static func checkRefreshRace(changeAccount: Bool) async throws {
        try await withDefaults { defaults in
            try saveTrust(defaults)
            let record = try pairRecord()
            record["state"] = "revoked"
            CompanionCloudStore.pair = record
            let service = makeService(role: .phone, defaults: defaults)
            var resume: CheckedContinuation<Void, Never>?
            CompanionCloudStore.beforeRecord = { await withCheckedContinuation { resume = $0 } }
            let refresh = Task { await service.refresh() }
            await waitUntil { resume != nil }
            let unpair = Task { await service.unpair() }
            await waitUntil { service.isBusy }
            if changeAccount { CompanionCloudStore.account = "different-account" }
            resume?.resume()
            await refresh.value
            await unpair.value
            expect(CompanionCloudStore.saveCount == 0, "No record needs revocation after the refresh")
            expect(CompanionCloudStore.removedPairs == (changeAccount ? [] : [trust.pairID]),
                   "Use captured trust for cleanup, but never use it in another account")
            expect((service.errorMessage != nil) == changeAccount, "An account switch must fail the captured operation")
        }
    }

    static func checkOfferRefreshRace() async throws {
        try await withDefaults { defaults in
            let record = try await makeOffer(defaults)
            try claimOffer(record, defaults: defaults)
            let service = makeService(role: .mac, defaults: defaults)
            var resume: CheckedContinuation<Void, Never>?
            CompanionCloudStore.beforeRecord = { await withCheckedContinuation { resume = $0 } }
            let refresh = Task { await service.refresh() }
            await waitUntil { resume != nil }
            let unpair = Task { await service.unpair() }
            await waitUntil { service.isBusy }
            resume?.resume()
            await refresh.value
            await unpair.value
            expect(CompanionCloudStore.pair?["state"] as? String == "revoked", "Retain captured offer identity while refresh claims the pair")
            expect(!service.hasLocalPairing && service.errorMessage == nil, "Cancel the exact claimed offer without stale state")
        }
    }
}
