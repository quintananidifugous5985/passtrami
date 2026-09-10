import SwiftUI

struct CompanionRootView: View {
    let service: CompanionService
    @Bindable var notifications: CompanionNotifications
    @State private var pairingCode = ""
    @State private var pendingPairingCode: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if service.pairedDevice != nil {
                    CompanionRequestsView(service: service)
                } else {
                    CompanionPairingView(service: service, code: $pairingCode)
                }
            }
            .navigationTitle(Bundle.main.displayName)
            .toolbar {
                if service.pairedDevice != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { notifications.showsSettings = true }
                    }
                }
            }
            .sheet(isPresented: $notifications.showsSettings) {
                CompanionSettingsView(service: service, notifications: notifications)
            }
            .onChange(of: service.pairedDevice?.id) { _, deviceID in
                if deviceID != nil {
                    pairingCode = ""
                    Task { await notifications.requestPermissionAfterPairing() }
                } else {
                    notifications.showsSettings = false
                }
            }
            .onChange(of: service.errorMessage) { _, message in
                if let message, service.accountAvailable { errorMessage = message }
            }
            .onChange(of: service.isBusy) { _, isBusy in
                if !isBusy {
                    Task {
                        await notifications.serviceBecameIdle()
                        await processPairingLink()
                    }
                }
            }
            .alert("Could Not Complete Request", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onOpenURL { url in
            guard let code = try? CompanionProtocol.pairingCode(from: url.absoluteString) else { return }
            pairingCode = code
            pendingPairingCode = code
            Task { await processPairingLink() }
        }
    }

    private func processPairingLink() async {
        guard !service.isBusy, let code = pendingPairingCode else { return }
        pendingPairingCode = nil
        await service.pair(code: code)
    }
}

private struct CompanionRequestsView: View {
    let service: CompanionService

    var body: some View {
        List {
            if let message = service.accountMessage, !service.accountAvailable {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            Section("Pending") {
                if service.pendingRequests.isEmpty {
                    ContentUnavailableView("No Pending Requests", systemImage: "checkmark.shield",
                                           description: Text("Requests from your Mac appear here."))
                } else {
                    ForEach(service.pendingRequests) { request in
                        CompanionPendingRow(request: request, isBusy: service.isBusy,
                                            approve: { Task { await service.approve(requestID: request.id) } },
                                            decline: { Task { await service.decline(requestID: request.id) } })
                    }
                }
            }
            if !service.history.isEmpty {
                Section("History") {
                    ForEach(service.history) { request in
                        CompanionHistoryRow(request: request)
                    }
                }
            }
        }
        .refreshable { await service.refresh() }
    }
}

struct CompanionPendingRow: View {
    let request: CompanionRequest
    let isBusy: Bool
    let approve: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CompanionRequestIdentity(domain: request.domain, username: request.username)
            HStack {
                Text("Expires").foregroundStyle(.secondary)
                Text(request.expiresAt, style: .relative).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            HStack {
                Button("Decline", action: decline).buttonStyle(.bordered)
                Button("Approve", action: approve).buttonStyle(.borderedProminent)
            }
            .disabled(isBusy)
        }
        .padding(.vertical, 6)
    }
}

private struct CompanionHistoryRow: View {
    let request: CompanionRequest

    var body: some View {
        HStack(alignment: .top) {
            CompanionRequestIdentity(domain: request.domain, username: request.username)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                CompanionRequestStatus(status: request.status)
                Text(request.decisionAt ?? request.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CompanionRequestIdentity: View {
    let domain: String
    let username: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(domain).font(.headline)
            Text(username).font(.subheadline).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}

struct CompanionRequestStatus: View {
    let status: CompanionRequest.Status

    var body: some View {
        HStack {
            switch status {
            case .pending: Text("Pending")
            case .approved: Text("Approved")
            case .declined: Text("Declined")
            case .expired: Text("Expired")
            case .cancelled: Text("Cancelled")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}
