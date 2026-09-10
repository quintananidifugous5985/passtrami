import CoreImage.CIFilterBuiltins
import SwiftUI

struct DevicesSettingsSection: View {
    let companion: CompanionService

    var body: some View {
        Group {
            DevicePairingSection(companion: companion)
            DeviceApprovalPolicySection(companion: companion)
            if companion.hasLocalPairing || !companion.pendingRequests.isEmpty || !companion.history.isEmpty {
                DeviceApprovalHistorySection(requests: companion.pendingRequests + companion.history)
            }
        }
    }
}

private struct DeviceApprovalPolicySection: View {
    let companion: CompanionService

    var body: some View {
        Section {
            if companion.approvalPolicyNeedsSetup {
                LabeledContent("Password Access") {
                    Button("Use Local Approval…") {
                        Task { await companion.setPhoneApprovalRequired(false) }
                    }
                    .disabled(companion.isBusy)
                }
            } else {
                Toggle("Require iPhone Approval", isOn: Binding(
                    get: { companion.requiresPhoneApproval },
                    set: { required in Task { await companion.setPhoneApprovalRequired(required) } }
                ))
                .toggleStyle(.switch)
                .disabled(companion.isBusy || (!companion.hasLocalPairing && !companion.requiresPhoneApproval))
            }
        } header: {
            Text("Approval")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if companion.approvalPolicyNeedsSetup {
                    Text("Password access is blocked. Pair an iPhone or authenticate on this Mac to use local approval.")
                } else if companion.requiresPhoneApproval, !companion.hasLocalPairing {
                    Text("Password access is blocked. Pair an iPhone or turn off this requirement on this Mac.")
                }
                Text("Turning this off requires authentication on this Mac. Unpairing does not turn it off.")
                Text("Phone approval briefly disables Touch ID for AutoFill across this Mac.")
            }
        }
    }
}

private struct DevicePairingSection: View {
    let companion: CompanionService

    var body: some View {
        Section {
            if let device = companion.pairedDevice {
                PairedDeviceRow(
                    name: device.name,
                    fingerprint: device.fingerprint,
                    isBusy: companion.isBusy,
                    unpair: { Task { await companion.unpair() } }
                )
            } else {
                HStack {
                    Text("iPhone")
                    Spacer()
                    if companion.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        Task { await companion.beginPairing() }
                    } label: {
                        if companion.pairingCode == nil {
                            Text("Pair…")
                        } else {
                            Text("New Code")
                        }
                    }
                    .disabled(!companion.accountAvailable || companion.isBusy)
                }
            }
            if companion.accountAvailable, let code = companion.pairingCode {
                DevicePairingCodeRow(
                    code: code,
                    url: companion.pairingURL,
                    expiresAt: companion.pairingExpiresAt
                )
            }
            if !companion.accountAvailable {
                LabeledContent("iCloud") {
                    Button("Retry") {
                        Task { await companion.refresh() }
                    }
                    .disabled(companion.isBusy)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect through your private iCloud account.")
                if let device = companion.localDevice {
                    Text("Mac identity: \(Text(device.fingerprint).font(.system(.caption, design: .monospaced)))")
                        .textSelection(.enabled)
                        .help("Compare this identity with the Mac shown on your iPhone.")
                }
                if let message = companion.accountMessage, !companion.accountAvailable {
                    Text(message)
                }
                if let error = companion.errorMessage, companion.accountAvailable || error != companion.accountMessage {
                    Text(error)
                }
            }
        }
    }
}

private struct PairedDeviceRow: View {
    let name: String
    let fingerprint: String
    let isBusy: Bool
    let unpair: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                Text(fingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Device identity: \(fingerprint)")
            }
            Spacer(minLength: 16)
            Button("Unpair", role: .destructive, action: unpair)
                .disabled(isBusy)
        }
    }
}

private struct DevicePairingCodeRow: View {
    let code: String
    let url: URL?
    let expiresAt: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            if let url {
                DevicePairingQRCode(url: url)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan with your iPhone, or enter this code in the app.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(code)
                    .font(.title3.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code: \(code)")
                if let expiresAt {
                    Text("Expires at \(expiresAt, format: .dateTime.hour().minute())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct DevicePairingQRCode: View {
    let url: URL
    @State private var qrCode: CGImage?

    var body: some View {
        ZStack {
            Color.white
            if let qrCode {
                Image(decorative: qrCode, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(16)
            }
        }
        .frame(width: 144, height: 144)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("iPhone pairing QR code")
        .task(id: url) {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(url.absoluteString.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else {
                qrCode = nil
                return
            }
            let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
            qrCode = CIContext().createCGImage(scaled, from: scaled.extent)
        }
    }
}

private struct DeviceApprovalHistorySection: View {
    let requests: [CompanionRequest]

    var body: some View {
        Section {
            if requests.isEmpty {
                Text("No requests yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(requests) { request in
                            VStack(spacing: 0) {
                                DeviceApprovalHistoryRow(
                                    domain: request.domain,
                                    username: request.username,
                                    date: request.decisionAt ?? request.createdAt,
                                    status: request.status
                                )
                                .padding(.vertical, 8)
                                if request.id != requests.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(requests.count) * 58, 180))
                .accessibilityLabel("Approval history")
            }
        } header: {
            Text("Recent Requests")
        }
    }
}

private struct DeviceApprovalHistoryRow: View {
    let domain: String
    let username: String
    let date: Date
    let status: CompanionRequest.Status

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(domain)
                    .lineLimit(1)
                    .help(domain)
                Text(username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(username)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                DeviceApprovalStatus(status: status)
                Text(date, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceApprovalStatus: View {
    let status: CompanionRequest.Status

    var body: some View {
        switch status {
        case .pending: Text("Pending")
        case .approved: Text("Approved")
        case .declined: Text("Declined")
        case .expired: Text("Expired")
        case .cancelled: Text("Cancelled")
        }
    }
}
