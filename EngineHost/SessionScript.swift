import Foundation
import JavaScriptCore

@MainActor
// The only Swift–JavaScript boundary: JSON events in, native operation messages out.
final class SessionScript {
    let context: JSContext
    private let receiveFunction: JSValue

    init(directory: URL, onPost: @escaping (String) -> Void, onFailure: @escaping () -> Void) throws {
        guard let context = JSContext() else {
            throw EngineFailure("javascript", "Could not start JavaScriptCore.")
        }
        self.context = context
        let post: @convention(block) (String) -> Void = onPost
        let uuid: @convention(block) () -> String = { UUID().uuidString }
        let hostname: @convention(block) (String) -> String? = { Self.hostname($0) }
        context.setObject(post, forKeyedSubscript: "__nativePost" as NSString)
        context.setObject(uuid, forKeyedSubscript: "__uuid" as NSString)
        context.setObject(hostname, forKeyedSubscript: "__hostname" as NSString)
        // Exception text can include credential data. Report only a fixed error.
        context.exceptionHandler = { context, exception in
            context?.exception = exception
            onFailure()
        }
        for name in ["credentials.js", "session.js"] {
            let url = directory.appendingPathComponent(name)
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
            guard context.exception == nil else {
                throw EngineFailure("javascript", "Could not load the password service.")
            }
        }
        guard let receive = context.objectForKeyedSubscript("Aster")?.objectForKeyedSubscript("receive"),
              !receive.isUndefined else {
            throw EngineFailure("javascript", "The password service is incomplete.")
        }
        receiveFunction = receive
    }

    func receive(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        receiveFunction.call(withArguments: [text])
    }

    static func hostname(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_:[]").inverted) == nil else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}
