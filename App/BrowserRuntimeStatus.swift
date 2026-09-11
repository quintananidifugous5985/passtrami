import AppKit
import Observation

struct BrowserRuntimeStatus: Decodable, Sendable {
    enum Phase: String, Decodable, Sendable {
        case idle, checking, downloading, installing, ready, failed

        var isBusy: Bool { self == .checking || self == .downloading || self == .installing }
    }

    var phase: Phase
    var fraction: Double?
    var receivedBytes: Int64?
    var totalBytes: Int64?
    var appPath: String?
    var message: String?
}

@MainActor
@Observable
final class BrowserRuntimeModel {
    private(set) var status = BrowserRuntimeStatus(phase: .idle)
    @ObservationIgnored var onDownload: (() -> Void)?

    func receive(_ status: BrowserRuntimeStatus) { self.status = status }

    func download() {
        guard !status.phase.isBusy, status.phase != .ready else { return }
        status = BrowserRuntimeStatus(phase: .checking)
        onDownload?()
    }

    func serviceFailed(_ message: String) {
        guard status.phase.isBusy else { return }
        status = BrowserRuntimeStatus(phase: .failed, message: message)
    }

    func pauseSetup() {
        if status.phase.isBusy { status = BrowserRuntimeStatus(phase: .idle) }
    }

    func revealInFinder() {
        guard status.phase == .ready, let path = status.appPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
