import SwiftUI

struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            StartupSettingsSection(model: model)
            CommandLineSettingsSection(model: model)
            MCPSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.25), value: model.mcpEnabled)
        .labeledContentStyle(CenteredLabeledContentStyle())
        .scrollContentBackground(.hidden)
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(.accentColor)
        .frame(
            minWidth: 480, idealWidth: 550, maxWidth: .infinity,
            minHeight: 420, idealHeight: 440, maxHeight: .infinity
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
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("aster")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("~/.local/bin/aster")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        if model.cliInstalled {
                            Button("Reveal in Finder", systemImage: "arrow.up.right.square.fill", action: model.revealCLI)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .controlSize(.mini)
                                .font(.caption)
                                .help("Reveal in Finder")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                if model.cliInstalled {
                    Button("Uninstall", role: .destructive, action: model.uninstallCLI)
                        .tint(.red)
                } else {
                    Button("Install…", action: model.installCLI)
                }
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

private struct MCPSettingsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section {
            VStack(spacing: 0) {
                Toggle("Enable MCP", isOn: $model.mcpEnabled)
                    .toggleStyle(.switch)
                if model.mcpEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        LabeledContent("Server Configuration") {
                            Button("Copy Configuration", action: model.copyMCPConfiguration)
                        }
                        if let error = model.mcpError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 10)
                    .transition(.opacity)
                }
            }
            .clipped()
        } header: {
            Text("MCP")
        } footer: {
            Text("Lets AI agents use passwords without including password values in session transcripts.")
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
