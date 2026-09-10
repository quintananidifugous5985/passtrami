import CryptoKit
import Foundation

enum CompanionRole: String, Codable, Sendable {
    case mac, phone
}

struct CompanionDevice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: CompanionRole
    let publicKey: Data

    var fingerprint: String {
        let hex = SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map {
            String(hex.dropFirst($0).prefix(4))
        }.joined(separator: " ")
    }
}

struct CompanionRequest: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending, approved, declined, expired, cancelled
    }

    let id: String
    let pairID: String
    let macID: String
    let phoneID: String
    let domain: String
    let username: String
    let createdAt: Date
    let expiresAt: Date
    var status: Status
    var decisionAt: Date?

    func effectiveStatus(at date: Date = Date()) -> Status {
        status == .pending && expiresAt <= date ? .expired : status
    }
}

enum CompanionError: LocalizedError, Sendable {
    case message(String)
    case invalidSignature
    case expired
    case declined
    case cancelled
    case alreadyUsed
    case notPaired
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .invalidSignature: "The device response could not be verified. Unpair the devices and pair them again."
        case .expired: "The approval request expired. Try again."
        case .declined: "The request was declined on your iPhone."
        case .cancelled: "The approval request was cancelled."
        case .alreadyUsed: "This approval has already been used."
        case .notPaired: "Pair an iPhone in Settings before you request approval."
        case .accountUnavailable: "Sign in to the same Apple Account on both devices and enable iCloud for this app."
        }
    }
}

struct CompanionPairingOffer: Codable, Sendable {
    let pairID: String
    let mac: CompanionDevice
    let codeDigest: Data
    let expiresAt: Date
}

struct CompanionPairingReceipt: Codable, Sendable {
    let pairID: String
    let mac: CompanionDevice
    let phone: CompanionDevice
}

struct CompanionTrust: Codable, Sendable {
    let accountID: String
    let pairID: String
    let mac: CompanionDevice
    let phone: CompanionDevice
}

struct CompanionSignedRequest: Codable, Sendable {
    let request: CompanionRequest
    let signature: Data
}

struct CompanionDecision: Codable, Sendable {
    let requestID: String
    let requestDigest: Data
    let pairID: String
    let phoneID: String
    let approved: Bool
    let decidedAt: Date
}

struct CompanionSignedDecision: Codable, Sendable {
    let decision: CompanionDecision
    let signature: Data
}

enum CompanionProtocol {
    static let pairingLifetime: TimeInterval = 5 * 60
    static let requestLifetime: TimeInterval = 2 * 60

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Keep Date's exact reference-time value stable when a signed message is decoded and encoded again.
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(type, from: data)
    }

    static func pairingCode(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if let url = URLComponents(string: trimmed), url.scheme != nil {
            guard url.scheme == "passtrami", url.host == "pair",
                  let code = url.queryItems?.first(where: { $0.name == "code" })?.value else {
                throw CompanionError.message("Scan a pairing code from the Mac app, or enter its code.")
            }
            source = code
        } else {
            source = trimmed
        }
        let normalized = source.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        guard normalized.count == 12, normalized.allSatisfy(alphabet.contains) else {
            throw CompanionError.message("Enter the 12-character code shown on your Mac.")
        }
        return normalized
    }

    static func digest(code: String) -> Data { Data(SHA256.hash(data: Data(code.utf8))) }

    static func pairingProof(code: String, receipt: CompanionPairingReceipt) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: try encode(receipt), using: SymmetricKey(data: Data(code.utf8))))
    }

    static func verifyPairingProof(_ proof: Data, code: String, receipt: CompanionPairingReceipt) throws {
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: try encode(receipt),
                                                    using: SymmetricKey(data: Data(code.utf8))) else {
            throw CompanionError.invalidSignature
        }
    }

    static func verify(_ signature: Data, data: Data, publicKey: Data) throws {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let value = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              key.isValidSignature(value, for: data) else { throw CompanionError.invalidSignature }
    }

    static func verifyRequest(_ signed: CompanionSignedRequest, trust: CompanionTrust, now: Date) throws {
        let request = signed.request
        guard request.pairID == trust.pairID, request.macID == trust.mac.id,
              request.phoneID == trust.phone.id, request.status == .pending,
              request.decisionAt == nil, request.expiresAt > request.createdAt,
              request.expiresAt.timeIntervalSince(request.createdAt) <= requestLifetime + 1,
              request.createdAt <= now.addingTimeInterval(30) else { throw CompanionError.invalidSignature }
        try verify(signed.signature, data: encode(request), publicKey: trust.mac.publicKey)
    }

    static func verifyDecision(_ signed: CompanionSignedDecision, for request: CompanionSignedRequest,
                               trust: CompanionTrust, consumed: Bool, now: Date) throws {
        if consumed { throw CompanionError.alreadyUsed }
        try verifyRequest(request, trust: trust, now: now)
        let decision = signed.decision
        guard decision.requestID == request.request.id, decision.pairID == trust.pairID,
              decision.phoneID == trust.phone.id,
              decision.requestDigest == Data(SHA256.hash(data: try encode(request.request))),
              decision.decidedAt >= request.request.createdAt,
              decision.decidedAt < request.request.expiresAt,
              decision.decidedAt <= now.addingTimeInterval(30) else { throw CompanionError.invalidSignature }
        try verify(signed.signature, data: encode(decision), publicKey: trust.phone.publicKey)
        if request.request.expiresAt <= now { throw CompanionError.expired }
    }
}
