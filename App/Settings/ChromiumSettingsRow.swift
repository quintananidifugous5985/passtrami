import SwiftUI

struct ChromiumSettingsRow: View {
    let model: BrowserRuntimeModel
    let accessAvailable: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("Chromium")
                if accessAvailable && model.status.phase == .ready {
                    Button("Reveal in Finder", systemImage: "arrow.up.right.square.fill", action: model.revealInFinder)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .controlSize(.mini)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Reveal in Finder")
                }
            }
            Spacer(minLength: 16)
            if accessAvailable {
                ChromiumStatusControl(status: model.status, download: model.download)
            } else {
                Text("Waiting for access").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChromiumDownloadProgress: View {
    let status: BrowserRuntimeStatus

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Group {
                if let fraction = status.fraction {
                    ProgressView(value: fraction, total: 1)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .controlSize(.small)
            .accessibilityLabel("Downloading Chromium")
            if let received = status.receivedBytes {
                ChromiumDownloadSize(received: received, total: status.totalBytes)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 180)
    }
}

private struct ChromiumDownloadSize: View {
    let received: Int64
    let total: Int64?

    var body: some View {
        if let total, total > 0 {
            Text("\(Double(received) / 1_000_000, format: .number.precision(.fractionLength(1))) MB of \(Double(total) / 1_000_000, format: .number.precision(.fractionLength(1))) MB")
        } else {
            Text("\(Double(received) / 1_000_000, format: .number.precision(.fractionLength(1))) MB")
        }
    }
}

private struct ChromiumStatusControl: View {
    let status: BrowserRuntimeStatus
    let download: () -> Void

    var body: some View {
        switch status.phase {
        case .idle:
            Button("Download", action: download)
        case .checking:
            ChromiumSetupProgress(title: "Checking…")
        case .downloading:
            ChromiumDownloadProgress(status: status)
        case .installing:
            ChromiumSetupProgress(title: "Installing…")
        case .ready:
            Text("Installed").foregroundStyle(.secondary)
        case .failed:
            Button("Retry", action: download)
        }
    }
}

private struct ChromiumSetupProgress: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.small)
        }
    }
}
