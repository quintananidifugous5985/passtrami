import CloudKit
import Foundation

@MainActor
final class CompanionCloudStore {
    static let containerIdentifier = "iCloud.io.zats.Passtrami"
    static let zoneID = CKRecordZone.ID(zoneName: "PasstramiCompanion", ownerName: CKCurrentUserDefaultName)
    static let pairRecordID = CKRecord.ID(recordName: "active-pair", zoneID: zoneID)
    static let requestRecordType = "PasstramiRequest"
    static let notificationCategory = "passtrami.approval"
    static let macSubscriptionID = "mac-companion-zone"

    let container = CKContainer(identifier: containerIdentifier)
    var database: CKDatabase { container.privateCloudDatabase }
    private var preparedAccount: String?
    private var subscribedMacAccount: String?

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CompanionError.accountUnavailable }
        return try await container.userRecordID().recordName
    }

    static func requestID(_ id: String) -> CKRecord.ID { CKRecord.ID(recordName: id, zoneID: zoneID) }
    static func phoneSubscriptionID(pairID: String) -> String { "phone-approvals-\(pairID)" }

    func prepareZone(accountID: String) async throws {
        guard preparedAccount != accountID else { return }
        _ = try await database.save(CKRecordZone(zoneID: Self.zoneID))
        preparedAccount = accountID
    }

    func subscribeToMacChanges(accountID: String) async throws {
        guard subscribedMacAccount != accountID else { return }
        let subscription = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.macSubscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        let result = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        guard let saved = result.saveResults[Self.macSubscriptionID] else {
            throw CompanionError.message("iCloud did not enable device change notifications. Try again.")
        }
        _ = try saved.get()
        subscribedMacAccount = accountID
    }

    func record(_ id: CKRecord.ID) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    @discardableResult
    func save(_ record: CKRecord) async throws -> CKRecord {
        let result = try await database.modifyRecords(saving: [record], deleting: [],
                                                     savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[record.recordID] else {
            throw CompanionError.message("iCloud did not save the change. Try again.")
        }
        return try saved.get()
    }

    func save(_ records: [CKRecord]) async throws {
        let result = try await database.modifyRecords(saving: records, deleting: [],
                                                     savePolicy: .ifServerRecordUnchanged, atomically: true)
        try Self.checkSaveResults(result.saveResults, for: records)
    }

    static func checkSaveResults(_ results: [CKRecord.ID: Result<CKRecord, any Error>], for records: [CKRecord]) throws {
        var failures: [CKRecord.ID: any Error] = [:]
        for record in records {
            guard let saved = results[record.recordID] else {
                failures[record.recordID] = CompanionError.message("iCloud did not save the change. Try again.")
                continue
            }
            if case .failure(let error) = saved { failures[record.recordID] = error }
        }
        guard failures.isEmpty else {
            throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: failures])
        }
    }

    // The operation must fetch and validate fresh records on every attempt.
    // Never retry an uncertain write result or resubmit stale CKRecord instances.
    static func retryRecordConflicts(_ operation: () async throws -> Void) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                try await operation()
                return
            } catch {
                let errors = recordErrors(error)
                let hasConflict = errors.contains { ($0 as? CKError)?.code == .serverRecordChanged }
                let onlyConflicts = errors.allSatisfy {
                    guard let code = ($0 as? CKError)?.code else { return false }
                    return code == .serverRecordChanged || code == .batchRequestFailed
                }
                guard attempt < 2, hasConflict, onlyConflicts else { throw error }
            }
        }
    }

    private static func recordErrors(_ error: any Error) -> [any Error] {
        guard let error = error as? CKError, error.code == .partialFailure,
              let partialErrors = error.partialErrorsByItemID, !partialErrors.isEmpty else { return [error] }
        return partialErrors.values.flatMap { recordErrors($0) }
    }

    func requests(pairID: String) async throws -> [CKRecord] {
        let query = CKQuery(recordType: Self.requestRecordType, predicate: NSPredicate(format: "pairID == %@", pairID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let result = try await database.records(matching: query, inZoneWith: Self.zoneID, resultsLimit: 100)
            return try result.matchResults.map { try $0.1.get() }
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
    }

    func subscribe(pairID: String) async throws {
        try await Self.savePhoneSubscription(pairID: pairID) { subscription in
            _ = try await database.save(subscription)
        }
    }

    static func savePhoneSubscription(pairID: String, save: (CKSubscription) async throws -> Void) async throws {
        let subscriptionID = Self.phoneSubscriptionID(pairID: pairID)
        let query = CKQuerySubscription(recordType: Self.requestRecordType,
            predicate: NSPredicate(format: "pairID == %@ AND status == %@", pairID, CompanionRequest.Status.pending.rawValue),
            subscriptionID: subscriptionID, options: .firesOnRecordCreation)
        query.zoneID = Self.zoneID
        let info = CKSubscription.NotificationInfo()
        info.title = "Password approval"
        info.alertBody = "Open the app to review a request from your Mac."
        info.soundName = "default"
        info.category = Self.notificationCategory
        info.desiredKeys = ["requestID"]
        info.shouldSendMutableContent = true
        query.notificationInfo = info
        try await save(query)
    }

    func removeSubscription(pairID: String) async throws {
        do { _ = try await database.deleteSubscription(withID: Self.phoneSubscriptionID(pairID: pairID)) }
        catch let error as CKError where error.code == .unknownItem { }
    }
}
