import CloudKit
import CryptoKit
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

func rejects(_ label: String, _ operation: () throws -> Void) {
    do {
        try operation()
        preconditionFailure("Accepted \(label)")
    } catch { }
}

let macKey = P256.Signing.PrivateKey()
let phoneKey = P256.Signing.PrivateKey()
let otherKey = P256.Signing.PrivateKey()
let mac = CompanionDevice(id: "mac", name: "Test Mac", role: .mac, publicKey: macKey.publicKey.x963Representation)
let phone = CompanionDevice(id: "phone", name: "iPhone", role: .phone, publicKey: phoneKey.publicKey.x963Representation)
let trust = CompanionTrust(accountID: "account", pairID: "pair", mac: mac, phone: phone)
let now = Date(timeIntervalSince1970: 1_800_000_000)
let request = CompanionRequest(id: UUID().uuidString, pairID: trust.pairID, macID: mac.id, phoneID: phone.id,
    domain: "example.com", username: "test@example.com", createdAt: now,
    expiresAt: now.addingTimeInterval(120), status: .pending)
let requestBytes = try CompanionProtocol.encode(request)
let signedRequest = CompanionSignedRequest(request: request, signature: try macKey.signature(for: requestBytes).derRepresentation)
let decision = CompanionDecision(requestID: request.id, requestDigest: Data(SHA256.hash(data: requestBytes)),
    pairID: trust.pairID, phoneID: phone.id, approved: true, decidedAt: now.addingTimeInterval(1))
let signedDecision = CompanionSignedDecision(decision: decision,
    signature: try phoneKey.signature(for: CompanionProtocol.encode(decision)).derRepresentation)

try CompanionProtocol.verifyRequest(signedRequest, trust: trust, now: now)
try CompanionProtocol.verifyDecision(signedDecision, for: signedRequest, trust: trust, consumed: false, now: now.addingTimeInterval(2))
let decodedRequest = try CompanionProtocol.decode(CompanionRequest.self, from: requestBytes)
expect(decodedRequest == request, "Signed request serialization must round trip")
expect(request.effectiveStatus(at: now.addingTimeInterval(120)) == .expired, "Expiry must occur at the deadline")
for _ in 0..<100 {
    let date = Date()
    let liveRequest = CompanionRequest(id: UUID().uuidString, pairID: trust.pairID, macID: mac.id, phoneID: phone.id,
        domain: request.domain, username: request.username, createdAt: date,
        expiresAt: date.addingTimeInterval(120), status: .pending)
    let bytes = try CompanionProtocol.encode(liveRequest)
    let decoded = try CompanionProtocol.decode(CompanionRequest.self, from: bytes)
    expect(decoded == liveRequest, "Live dates must round trip exactly")
    expect(try! CompanionProtocol.encode(decoded) == bytes, "Signed encoding must be stable after CloudKit decoding")
}

rejects("an already consumed approval") {
    try CompanionProtocol.verifyDecision(signedDecision, for: signedRequest, trust: trust, consumed: true, now: now.addingTimeInterval(2))
}
rejects("an expired approval") {
    try CompanionProtocol.verifyDecision(signedDecision, for: signedRequest, trust: trust, consumed: false, now: now.addingTimeInterval(120))
}
rejects("an approval from a different phone key") {
    let forged = CompanionSignedDecision(decision: decision,
        signature: try otherKey.signature(for: CompanionProtocol.encode(decision)).derRepresentation)
    try CompanionProtocol.verifyDecision(forged, for: signedRequest, trust: trust, consumed: false, now: now.addingTimeInterval(2))
}
rejects("an approval for a different request") {
    let other = CompanionRequest(id: UUID().uuidString, pairID: trust.pairID, macID: mac.id, phoneID: phone.id,
        domain: request.domain, username: request.username, createdAt: now, expiresAt: request.expiresAt, status: .pending)
    let signed = CompanionSignedRequest(request: other, signature: try macKey.signature(for: CompanionProtocol.encode(other)).derRepresentation)
    try CompanionProtocol.verifyDecision(signedDecision, for: signed, trust: trust, consumed: false, now: now.addingTimeInterval(2))
}
rejects("an approval for a changed account") {
    let changed = CompanionRequest(id: request.id, pairID: trust.pairID, macID: mac.id, phoneID: phone.id,
        domain: "attacker.example", username: request.username, createdAt: now, expiresAt: request.expiresAt, status: .pending)
    try CompanionProtocol.verifyRequest(CompanionSignedRequest(request: changed, signature: signedRequest.signature), trust: trust, now: now)
}
rejects("an approval from a revoked pair") {
    let other = CompanionTrust(accountID: trust.accountID, pairID: "new-pair", mac: mac, phone: phone)
    try CompanionProtocol.verifyDecision(signedDecision, for: signedRequest, trust: other, consumed: false, now: now.addingTimeInterval(2))
}
rejects("a forged Mac request") {
    let forged = CompanionSignedRequest(request: request, signature: try otherKey.signature(for: requestBytes).derRepresentation)
    try CompanionProtocol.verifyRequest(forged, trust: trust, now: now)
}

let code = try CompanionProtocol.pairingCode(from: "abcd-efgh-jkmn")
expect(code == "ABCDEFGHJKMN", "Manual codes must accept lowercase and separators")
let scannedCode = try CompanionProtocol.pairingCode(from: "passtrami://pair?code=ABCD-EFGH-JKMN")
expect(scannedCode == code, "QR URL and manual entry must agree")
rejects("a foreign pairing URL") { _ = try CompanionProtocol.pairingCode(from: "https://example.com/pair?code=ABCD-EFGH-JKMN") }
rejects("a short code") { _ = try CompanionProtocol.pairingCode(from: "ABCD") }
let receipt = CompanionPairingReceipt(pairID: trust.pairID, mac: mac, phone: phone)
let proof = try CompanionProtocol.pairingProof(code: code, receipt: receipt)
try CompanionProtocol.verifyPairingProof(proof, code: code, receipt: receipt)
rejects("a pairing receipt with a different code") {
    try CompanionProtocol.verifyPairingProof(proof, code: "ABCDEFGHJKMP", receipt: receipt)
}
rejects("a pairing receipt with a substituted phone") {
    let foreignPhone = CompanionDevice(id: "other", name: "iPhone", role: .phone, publicKey: otherKey.publicKey.x963Representation)
    try CompanionProtocol.verifyPairingProof(proof, code: code,
        receipt: CompanionPairingReceipt(pairID: trust.pairID, mac: mac, phone: foreignPhone))
}

@MainActor
func rejectsAsync(_ label: String, matching matches: (any Error) -> Bool,
                  _ operation: () async throws -> Void) async {
    do {
        try await operation()
        preconditionFailure("Accepted \(label)")
    } catch {
        expect(matches(error), "Wrong error for \(label): \(error)")
    }
}

@MainActor
func checkRecordConflictRetries() async throws {
    let pairID = CKRecord.ID(recordName: "test-pair")
    let requestID = CKRecord.ID(recordName: "test-request")
    let pairRecord = CKRecord(recordType: "Pair", recordID: pairID)
    let requestRecord = CKRecord(recordType: "Request", recordID: requestID)
    let conflict = CKError(.serverRecordChanged)
    let batchFailure = CKError(.batchRequestFailed)
    let atomicConflict = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
        pairID: conflict, requestID: batchFailure
    ]])

    // The phone commits approval after the Mac reads the pair but before it reads the request.
    var pairVersion = 0
    var serverDecision: CompanionSignedDecision?
    var consumed = false
    var consumptionCount = 0
    var readVersions: [Int] = []
    try await CompanionCloudStore.retryRecordConflicts {
        let readPairVersion = pairVersion
        readVersions.append(readPairVersion)
        if readVersions.count == 1 {
            pairVersion += 1
            serverDecision = signedDecision
        }
        guard let currentDecision = serverDecision else { preconditionFailure("Missing test approval") }
        try CompanionProtocol.verifyDecision(currentDecision, for: signedRequest, trust: trust,
                                             consumed: consumed, now: now.addingTimeInterval(2))
        if readPairVersion != pairVersion {
            expect(!consumed && consumptionCount == 0, "A conflicted atomic save must not consume approval")
            // Put batchRequestFailed first to reproduce the error that previously hid the conflict.
            try CompanionCloudStore.checkSaveResults([
                requestID: .failure(batchFailure), pairID: .failure(conflict)
            ], for: [requestRecord, pairRecord])
            preconditionFailure("Accepted a stale pair version")
        }
        try CompanionCloudStore.checkSaveResults([
            requestID: .success(requestRecord), pairID: .success(pairRecord)
        ], for: [requestRecord, pairRecord])
        consumed = true
        consumptionCount += 1
    }
    expect(readVersions == [0, 1], "Conflict recovery must refetch the current pair version")
    expect(consumed && consumptionCount == 1, "A fresh approval must be consumed exactly once")

    do {
        try CompanionCloudStore.checkSaveResults([
            requestID: .failure(batchFailure), pairID: .failure(conflict)
        ], for: [requestRecord, pairRecord])
        preconditionFailure("Accepted failed record saves")
    } catch let error as CKError {
        expect(error.code == .partialFailure, "Atomic save errors must be aggregated")
        let failures = error.partialErrorsByItemID
        expect(failures?.count == 2, "All failed record results must be preserved")
        expect((failures?[pairID] as? CKError)?.code == .serverRecordChanged, "The real conflict must be preserved")
        expect((failures?[requestID] as? CKError)?.code == .batchRequestFailed, "The aborted record must be preserved")
    }

    // Each conflict retry must read and validate current state before it can consume approval.
    for invalidation in ["revoked pair", "consumed approval", "expired request"] {
        var pairIsActive = true
        var alreadyConsumed = false
        var validationTime = now.addingTimeInterval(2)
        var attempts = 0
        var successfulSaves = 0
        await rejectsAsync(invalidation, matching: { error in
            guard let error = error as? CompanionError else { return false }
            return switch (invalidation, error) {
            case ("revoked pair", .notPaired), ("consumed approval", .alreadyUsed), ("expired request", .expired): true
            default: false
            }
        }) {
            try await CompanionCloudStore.retryRecordConflicts {
                attempts += 1
                guard pairIsActive else { throw CompanionError.notPaired }
                try CompanionProtocol.verifyDecision(signedDecision, for: signedRequest, trust: trust,
                    consumed: alreadyConsumed, now: validationTime)
                if attempts == 1 {
                    switch invalidation {
                    case "revoked pair": pairIsActive = false
                    case "consumed approval": alreadyConsumed = true
                    case "expired request": validationTime = request.expiresAt
                    default: preconditionFailure("Unknown invalidation")
                    }
                    throw atomicConflict
                }
                successfulSaves += 1
            }
        }
        expect(attempts == 2, "\(invalidation) must be checked again after refetch")
        expect(successfulSaves == 0, "\(invalidation) must prevent consumption")
    }

    let nestedConflict = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
        pairID: atomicConflict, requestID: batchFailure
    ]])
    for error in [conflict, atomicConflict, nestedConflict] {
        var attempts = 0
        try await CompanionCloudStore.retryRecordConflicts {
            attempts += 1
            if attempts == 1 { throw error }
        }
        expect(attempts == 2, "Confirmed direct and nested record conflicts must retry")
    }

    let fatalError = CKError(.permissionFailure)
    let networkError = CKError(.networkFailure)
    let noConflict = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [pairID: batchFailure]])
    let mixedFatal = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
        pairID: atomicConflict, requestID: fatalError
    ]])
    let mixedNetwork = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
        pairID: conflict, requestID: networkError
    ]])
    for error in [fatalError, networkError, batchFailure, noConflict, mixedFatal, mixedNetwork,
                  CKError(.partialFailure), CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [:]])] {
        var attempts = 0
        await rejectsAsync("non-retryable CloudKit error \(error.code)", matching: { ($0 as? CKError)?.code == error.code }) {
            try await CompanionCloudStore.retryRecordConflicts {
                attempts += 1
                throw error
            }
        }
        expect(attempts == 1, "Fatal, ambiguous, and unconfirmed errors must not retry")
    }

    var missingResultAttempts = 0
    await rejectsAsync("a missing result beside a conflict", matching: { !($0 is CancellationError) }) {
        try await CompanionCloudStore.retryRecordConflicts {
            missingResultAttempts += 1
            try CompanionCloudStore.checkSaveResults([pairID: .failure(conflict)], for: [pairRecord, requestRecord])
        }
    }
    expect(missingResultAttempts == 1, "An incomplete save result must not be treated as a confirmed conflict")

    var boundedAttempts = 0
    await rejectsAsync("an unresolved conflict", matching: { ($0 as? CKError)?.code == .serverRecordChanged }) {
        try await CompanionCloudStore.retryRecordConflicts {
            boundedAttempts += 1
            throw conflict
        }
    }
    expect(boundedAttempts == 3, "Conflict retry must stop after three total attempts")

    var cancellationAttempts = 0
    let cancelledRetry = Task { @MainActor in
        try await CompanionCloudStore.retryRecordConflicts {
            cancellationAttempts += 1
            withUnsafeCurrentTask { $0?.cancel() }
            throw conflict
        }
    }
    await rejectsAsync("cancellation during conflict recovery", matching: { $0 is CancellationError }) {
        try await cancelledRetry.value
    }
    expect(cancellationAttempts == 1, "Cancellation must stop before the next attempt")

    var cancelledBeforeStartAttempts = 0
    let cancelledBeforeStart = Task { @MainActor in
        try await CompanionCloudStore.retryRecordConflicts { cancelledBeforeStartAttempts += 1 }
    }
    cancelledBeforeStart.cancel()
    await rejectsAsync("an already cancelled operation", matching: { $0 is CancellationError }) {
        try await cancelledBeforeStart.value
    }
    expect(cancelledBeforeStartAttempts == 0, "An already cancelled operation must not start")
}

try await checkRecordConflictRetries()
print("Companion checks passed: pairing binding, signatures, expiry, replay rejection, atomic conflict recovery, fresh-state validation, retry limits, and cancellation")
