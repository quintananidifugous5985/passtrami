import Foundation

struct EngineFailure: Error, Sendable {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}
