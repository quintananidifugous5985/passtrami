import SwiftUI

struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            StartupSettingsSection(model: model)
            CommandLineSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .labeledContentStyle(CenteredLabeledContentStyle())
        .scrollContentBackground(.hidden)
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(.accentColor)
        .frame(
            minWidth: 480, idealWidth: 550, maxWidth: .infinity,
            minHeight: 300, idealHeight: 360, maxHeight: .infinity
        )
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .ignoresSafeArea()
        }
    }
}

private struct StartupSettingsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section("Startup") {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Launch at Login", isOn: $model.launchAtLoginEnabled)
                    .toggleStyle(.switch)
                if let error = model.loginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if model.loginStatus == .requiresApproval {
                    Text("Approval is required in Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.loginStatus == .notFound {
                    Text("\(Bundle.main.displayName) could not be found by macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.loginStatus != .enabled && model.loginStatus != .notRegistered {
                    Text("Launch at Login is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.loginStatus == .requiresApproval {
                LabeledContent("Login Items") {
                    Button("Open…", action: model.openLoginItems)
                }
            }
        }
    }
}

private struct CommandLineSettingsSection: View {
    let model: SettingsModel

    var body: some View {
        Section("Command Line") {
            LabeledContent {
                if model.cliInstalled {
                    Button("Uninstall", action: model.uninstallCLI)
                } else {
                    Button("Install…", action: model.installCLI)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("aster")
                    Text("~/.local/bin/aster")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.cliError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.didInstallCLI {
                Text("Open a new terminal to use aster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CenteredLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            configuration.label
            Spacer(minLength: 16)
            configuration.content
        }
    }
}
