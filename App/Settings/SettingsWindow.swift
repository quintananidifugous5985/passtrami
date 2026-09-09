import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "Aster.SettingsWindow"
    private let model: SettingsModel
    private let didClose: () -> Void

    init(launchAtLogin: LaunchAtLoginController, didClose: @escaping () -> Void) {
        model = SettingsModel(launchAtLogin: launchAtLogin)
        self.didClose = didClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.title = "\(Bundle.main.displayName) Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }
        window.setContentSize(NSSize(width: 550, height: 360))
        window.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        model.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
    func windowWillClose(_ notification: Notification) { didClose() }
}

@MainActor
@Observable
final class SettingsModel {
    private let launchAtLogin: LaunchAtLoginController
    private let installer: CLIInstaller
    private(set) var loginStatus: SMAppService.Status = .notRegistered
    private(set) var loginError: String?
    private(set) var cliInstalled = false
    private(set) var cliError: String?
    private(set) var didInstallCLI = false

    var launchAtLoginEnabled: Bool {
        get { loginStatus == .enabled }
        set {
            launchAtLogin.setEnabled(newValue)
            refresh()
        }
    }

    init(launchAtLogin: LaunchAtLoginController, installer: CLIInstaller = CLIInstaller()) {
        self.launchAtLogin = launchAtLogin
        self.installer = installer
    }

    func refresh() {
        launchAtLogin.refresh()
        loginStatus = launchAtLogin.status
        loginError = launchAtLogin.operationError
        cliInstalled = installer.isInstalled
    }

    func openLoginItems() { launchAtLogin.openLoginItems() }

    func revealCLI() {
        guard installer.isInstalled else { return }
        NSWorkspace.shared.activateFileViewerSelecting([installer.commandURL])
    }

    func installCLI() {
        cliError = nil
        do {
            try installer.install()
            didInstallCLI = true
            refresh()
        } catch {
            cliError = error.localizedDescription
        }
    }

    func uninstallCLI() {
        cliError = nil
        do {
            try installer.uninstall()
            didInstallCLI = false
            refresh()
        } catch {
            cliError = error.localizedDescription
        }
    }
}
