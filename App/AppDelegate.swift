import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = EngineProcess()
    private let pinWindow = PINWindow()
    private let launchAtLogin = LaunchAtLoginController()
    private lazy var settings = SettingsWindow(launchAtLogin: launchAtLogin, onMCPChange: { [weak self] enabled in
        self?.engine.setMCPEnabled(enabled)
    }) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }
    private var statusItem: NSStatusItem!
    private let unlockItem = NSMenuItem(title: "Unlock…", action: nil, keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "Lock", action: nil, keyEquivalent: "")
    private var firstLockedEventHandled = false
    private var shutdownTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchAtLogin.applyInitialDefaultIfNeeded()
        createMenu()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        pinWindow.onSubmit = { [weak self] pin in self?.engine.send("pin", pin: pin) }
        pinWindow.onCancel = { [weak self] in self?.engine.send("lock") }
        startEngine()
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "\(Bundle.main.displayName) is starting")
        let menu = NSMenu()
        menu.autoenablesItems = false
        unlockItem.target = self
        unlockItem.action = #selector(unlock)
        unlockItem.isEnabled = false
        lockItem.target = self
        lockItem.action = #selector(lock)
        lockItem.isEnabled = false
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quit = NSMenuItem(title: "Quit \(Bundle.main.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        for item in [unlockItem, lockItem, .separator(), settingsItem, quit] {
            menu.addItem(item)
        }
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: Bundle.main.displayName)
        let mainSettings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        mainSettings.target = self
        appMenu.addItem(mainSettings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(Bundle.main.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
    }

    private func startEngine() {
        do { try engine.start() }
        catch { handle(EngineEvent(type: "state", state: .error, message: "Could not start the password service.")) }
    }

    private func handle(_ event: EngineEvent) {
        switch event.type {
        case "pinRequired": pinWindow.present()
        case "pinError": pinWindow.showError(event.message)
        case "state":
            guard let state = event.state else { return }
            updateMenu(state, message: event.message)
            if state == .unlocked {
                UserDefaults.standard.set(true, forKey: "didCompletePairing")
                pinWindow.dismiss()
            } else if state == .locked || state == .error {
                pinWindow.dismiss()
            }
            if state == .locked && !firstLockedEventHandled {
                firstLockedEventHandled = true
                if !UserDefaults.standard.bool(forKey: "didCompletePairing") { engine.send("unlock") }
            }
        default: break
        }
    }

    private func updateMenu(_ state: EngineState, message: String?) {
        let label: String
        switch state {
        case .starting: label = message ?? "Starting…"
        case .locked: label = "Locked"
        case .pairing: label = "Enter code to unlock"
        case .unlocked: label = "Unlocked"
        case .error: label = message ?? "Could not connect"
        }
        statusItem.button?.toolTip = "\(Bundle.main.displayName): " + label
        statusItem.button?.image = NSImage(systemSymbolName: state == .unlocked ? "lock.open.fill" : "lock.fill",
                                          accessibilityDescription: "\(Bundle.main.displayName): " + label)
        unlockItem.isEnabled = state == .locked || state == .error
        lockItem.title = state == .starting ? "Cancel Setup" : "Lock"
        lockItem.isEnabled = state == .starting || state == .unlocked || state == .pairing
    }

    @objc private func unlock() {
        if !engine.isRunning { startEngine() }
        engine.send("unlock")
    }

    @objc private func lock() { engine.send("lock") }
    @objc private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        settings.present()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shutdownTask == nil else { return .terminateLater }
        pinWindow.dismiss()
        shutdownTask = Task { [engine] in
            await engine.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
