import SwiftUI
import UIKit

struct CompanionSettingsView: View {
    let service: CompanionService
    let notifications: CompanionNotifications
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                if let device = service.pairedDevice {
                    Section("Paired Mac") {
                        Label(device.name, systemImage: "laptopcomputer")
                        LabeledContent("Fingerprint") {
                            Text(device.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("Unpair Mac", role: .destructive) { confirmsUnpair = true }
                            .disabled(service.isBusy)
                    }
                }
                if let device = service.localDevice {
                    Section {
                        LabeledContent("This iPhone") {
                            Text(device.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } footer: {
                        Text("Compare these fingerprints with the device details on your Mac.")
                    }
                }
                Section {
                    if notifications.authorizationStatus == .denied {
                        Button("Open Notification Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } else if notifications.authorizationStatus == .notDetermined {
                        Button("Enable Notifications") {
                            Task { await notifications.requestPermissionAfterPairing() }
                        }
                    } else {
                        LabeledContent("Notifications", value: String(localized: "Enabled"))
                    }
                } footer: {
                    Text("Get notified when your Mac needs approval. Opening a notification does not approve the request.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair this Mac?", isPresented: $confirmsUnpair, titleVisibility: .visible) {
                Button("Unpair Mac", role: .destructive) {
                    Task { await service.unpair() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This iPhone will no longer receive requests from your Mac.")
            }
        }
    }
}
