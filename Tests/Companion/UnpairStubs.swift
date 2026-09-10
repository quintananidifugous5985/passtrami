import CloudKit
import Foundation

@MainActor
final class TestApprovalPolicyStore {
    var required: Bool?
    var readError: (any Error)?
    var writeError: (any Error)?
    var reads = 0
    var writes: [Bool] = []

    var store: CompanionApprovalPolicyStore {
        CompanionApprovalPolicyStore(read: { [self] in
            reads += 1
            if let readError { throw readError }
            return required
        }, write: { [self] required in
            if let writeError { throw writeError }
            writes.append(required)
            self.required = required
        })
    }
}

// This executable compiles the production service against in-memory dependencies.
// It cannot construct a CloudKit container or use a Keychain signing key.
@MainActor
final class CompanionCloudStore {
    static let pairRecordID = CKRecord.ID(recordName: "active-pair")
    static let requestRecordType = "PasstramiRequest"
    static let notificationCategory = "passtrami.approval"
    static var account = "test-account"
    static var accountError: (any Error)?
    static var accountReads = 0
    static var pair: CKRecord?
    static var saveCount = 0
    static var removedPairs: [String] = []
    static var subscriptions: Set<String> = []
    static var beforeRecord: (() async -> Void)?
    static var beforeSave: (() throws -> Void)?

    static func reset() {
        account = "test-account"
        accountError = nil
        accountReads = 0
        pair = nil
        saveCount = 0
        removedPairs = []
        subscriptions = ["phone-approvals-old-pair", "phone-approvals-new-pair", "mac-companion-zone"]
        beforeRecord = nil
        beforeSave = nil
    }

    static func requestID(_ id: String) -> CKRecord.ID { CKRecord.ID(recordName: id) }
    static func retryRecordConflicts(_ operation: () async throws -> Void) async throws { try await operation() }
    func accountID() async throws -> String {
        Self.accountReads += 1
        if let error = Self.accountError { throw error }
        return Self.account
    }
    func prepareZone(accountID: String) async throws { }
    func subscribeToMacChanges(accountID: String) async throws { }
    func subscribe(pairID: String) async throws { }
    func requests(pairID: String) async throws -> [CKRecord] { [] }

    func record(_ id: CKRecord.ID) async throws -> CKRecord? {
        let snapshot = Self.pair?.copy() as? CKRecord
        if let action = Self.beforeRecord {
            Self.beforeRecord = nil
            await action()
        }
        return snapshot
    }

    @discardableResult
    func save(_ record: CKRecord) async throws -> CKRecord {
        if let action = Self.beforeSave {
            Self.beforeSave = nil
            try action()
        }
        Self.saveCount += 1
        Self.pair = record.copy() as? CKRecord
        return record
    }

    func save(_ records: [CKRecord]) async throws {
        preconditionFailure("Unpair tests must not write password requests")
    }

    func removeSubscription(pairID: String) async throws {
        Self.removedPairs.append(pairID)
        Self.subscriptions.remove("phone-approvals-\(pairID)")
    }
}

struct CompanionSigningKey: Sendable {
    let tag: Data
    let requiresPresence: Bool

    func publicKey() throws -> Data { Data(requiresPresence ? "phone-key".utf8 : "mac-key".utf8) }
    func sign(_ data: Data, reason: String) async throws -> Data {
        preconditionFailure("Unpair tests must not sign approvals")
    }
}
