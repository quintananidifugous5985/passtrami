import CryptoKit
import Foundation

@MainActor
final class ArchiveDownload: NSObject, @preconcurrency URLSessionDataDelegate {
    private let url: URL
    private let destination: URL
    private let expectedChecksum: String
    private let progress: @MainActor (String) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var length: Int64 = 0
    private var lastProgress = Date.distantPast
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false
    private var created = false
    private var cancelled = false

    init(url: URL, destination: URL, checksum: String, progress: @escaping @MainActor (String) -> Void) {
        self.url = url
        self.destination = destination
        expectedChecksum = checksum
        self.progress = progress
    }

    func run() async throws {
        if cancelled { throw EngineFailure("cancelled", "Browser setup was cancelled.") }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            self.session = session
            let task = session.dataTask(with: url)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        cancelled = true
        finish(EngineFailure("cancelled", "Browser setup was cancelled."))
    }

    private func finish(_ error: (any Error)?) {
        guard !finished else { return }
        finished = true
        try? file?.close()
        file = nil
        if error != nil, created { try? FileManager.default.removeItem(at: destination) }
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(EngineFailure("browser_download", "Chromium could not be downloaded. Try Unlock again."))
            return
        }
        do {
            file = try BrowserRuntime.createPrivateFile(destination)
            created = true
            length = response.expectedContentLength
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(EngineFailure("browser_download", "The Chromium download file could not be created."))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        do {
            try file?.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 1 {
                let amount = length > 0 ? "\(min(100, Int(Double(received) / Double(length) * 100)))%" : "\(received / 1_048_576) MB"
                progress("Downloading Chromium: \(amount)")
                lastProgress = now
            }
        } catch { finish(EngineFailure("browser_download", "The Chromium download could not be saved.")) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !finished else { return }
        if let error {
            let timeout = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorTimedOut
            finish(EngineFailure("browser_download", timeout
                ? "The Chromium download took too long. Try Unlock again."
                : "Chromium could not be downloaded. Check your connection, then try Unlock again."))
            return
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == expectedChecksum else {
            finish(EngineFailure("browser_checksum", "The Chromium download failed its checksum check. Try Unlock again."))
            return
        }
        do { try file?.synchronize(); finish(nil) }
        catch { finish(EngineFailure("browser_download", "The Chromium download could not be saved.")) }
    }
}
