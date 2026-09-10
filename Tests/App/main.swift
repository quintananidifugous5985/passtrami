import Foundation

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("passtrami-installer-\(UUID().uuidString)")
try manager.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: root) }

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let executable = root.appendingPathComponent("helper/passtrami")
try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
let home = root.appendingPathComponent("home")
let command = home.appendingPathComponent(".local/bin/passtrami")
let installer = CLIInstaller(executableURL: executable, homeURL: home)
expect(!installer.isInstalled, "Absent shortcut must not be installed")
try installer.uninstall()
try installer.install()
expect(installer.isInstalled, "Install must create shortcut")
let profile = home.appendingPathComponent(".zprofile")
let shellText = try String(contentsOf: profile, encoding: .utf8)
try installer.uninstall()
expect(!installer.isInstalled, "Uninstall must remove shortcut")
expect(manager.isExecutableFile(atPath: executable.path), "Uninstall must preserve helper")
let preservedShellText = try String(contentsOf: profile, encoding: .utf8)
expect(preservedShellText == shellText, "Uninstall must preserve shared shell PATH")
try installer.install()
expect(installer.isInstalled, "Reinstall must work")
try manager.removeItem(at: profile)
expect(installer.isInstalled, "Shortcut remains uninstallable without shell config")
try installer.uninstall()

@MainActor func expectConflict() throws {
    do {
        try installer.uninstall()
        preconditionFailure("Uninstall must reject another command")
    } catch CLIInstaller.InstallError.conflictingCommand { }
}

try Data("other command".utf8).write(to: command)
try expectConflict()
expect(manager.fileExists(atPath: command.path), "Uninstall must preserve foreign file")
try manager.removeItem(at: command)
let foreign = root.appendingPathComponent("foreign/passtrami")
try manager.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("foreign target".utf8).write(to: foreign)
try manager.createSymbolicLink(at: command, withDestinationURL: foreign)
try expectConflict()
expect((try? manager.destinationOfSymbolicLink(atPath: command.path)) != nil, "Uninstall must preserve foreign link")
expect(manager.fileExists(atPath: foreign.path), "Uninstall must preserve foreign target")

let bundleURL = root.appendingPathComponent("DisplayName.app")
try manager.createDirectory(at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
let plist: [String: Any] = ["CFBundleIdentifier": "io.zats.DisplayNameTest", "CFBundleName": "InternalName", "CFBundleDisplayName": "Display Name Test"]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
expect(Bundle(url: bundleURL)!.displayName == "Display Name Test", "Use display name, not internal name")

let defaultsDomain = "io.zats.Passtrami.MCPTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: defaultsDomain)!
defer { defaults.removePersistentDomain(forName: defaultsDomain) }
let mcpSettings = MCPSettings(defaults: defaults)
expect(!mcpSettings.isEnabled, "MCP must be disabled before the user enables it")
mcpSettings.isEnabled = true
expect(MCPSettings(defaults: defaults).isEnabled, "MCP enable choice must persist")
mcpSettings.isEnabled = false
expect(!MCPSettings(defaults: defaults).isEnabled, "MCP disable choice must persist")
let browserModel = BrowserRuntimeModel()
var downloadRequests = 0
browserModel.onDownload = { downloadRequests += 1 }
browserModel.download()
browserModel.download()
expect(downloadRequests == 1, "Repeated clicks must not start another download")
let progressEvent = try JSONDecoder().decode(EngineEvent.self, from: Data("""
{"type":"browserRuntime","browserRuntime":{"phase":"downloading","fraction":0.5,"receivedBytes":1024,"totalBytes":2048}}
""".utf8))
browserModel.receive(progressEvent.browserRuntime!)
expect(browserModel.status.fraction == 0.5 && browserModel.status.receivedBytes == 1024,
       "Engine progress must reach the Settings model")
browserModel.serviceFailed("The service stopped.")
expect(browserModel.status.phase == .failed, "An engine failure must not leave download progress stuck")
browserModel.download()
expect(downloadRequests == 2 && browserModel.status.phase == .checking, "Retry must start setup again")
browserModel.receive(BrowserRuntimeStatus(phase: .ready, appPath: "/test/Chromium.app"))
browserModel.serviceFailed("The password session stopped.")
browserModel.download()
expect(browserModel.status.phase == .ready && browserModel.status.appPath == "/test/Chromium.app",
       "Password session failure must not lose the installed runtime")
expect(downloadRequests == 2, "Installed runtime must not be downloaded again from Settings")
print("App tests passed: CLI installer, bundle name, MCP settings, and Chromium download state")
