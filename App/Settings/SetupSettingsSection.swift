import SwiftUI

struct SetupSettingsSection: View {
    let model: FullDiskAccessModel
    let browserRuntime: BrowserRuntimeModel

    var body: some View {
        Section {
            LabeledContent("Full Disk Access") {
                switch model.status {
                case .available:
                    Text("Allowed").foregroundStyle(.secondary)
                case .required:
                    Button("Open Settings…", action: model.openSettings)
                case .missingPreferences, .unavailable:
                    Button("Check Again", action: model.checkAgain)
                }
            }
            ChromiumSettingsRow(model: browserRuntime, accessAvailable: model.status == .available)
        } header: {
            Text("Setup")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if model.status == .required {
                    Text("Enable Full Disk Access for \(Bundle.main.displayName) in System Settings so it can manage Apple Passwords approval. Chromium setup will start when access is available. If macOS asks, quit and reopen the app.")
                } else if model.status == .missingPreferences {
                    Text("Open Safari once, then return here and choose Check Again.")
                } else if model.status == .unavailable {
                    Text("Apple Passwords settings could not be accessed. Setup is paused. Check again to continue.")
                }
                if model.settingsOpenFailed {
                    Text("Open System Settings → Privacy & Security → Full Disk Access.")
                }
                if model.status == .available, browserRuntime.status.phase == .failed,
                   let message = browserRuntime.status.message {
                    Text(message)
                }
                Text("\(Bundle.main.displayName) uses the Chromium runtime to connect securely to Apple Passwords, just like Apple’s iCloud Passwords extension.")
            }
        }
    }
}
