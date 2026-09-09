import AppKit
import SwiftUI

@MainActor
private final class PINPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PINWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let window: PINPanel
    private let field = NSTextField()
    private var hosting: NSHostingView<PINView>!
    private var passwordIcon: NSImage?
    private var appIcon = NSImage()

    override init() {
        // Matches LAAuthWindow's style mask in coreautha. See docs/pin-dialog.md.
        let alertStyle = NSWindow.StyleMask(rawValue: UInt(1) << 33)
        window = PINPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 240),
                          styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, alertStyle],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Unlock \(Bundle.main.displayName)"
        window.titlebarAppearsTransparent = true
        window.setValue(true, forKey: "titlebarHidden")
        window.titleVisibility = .hidden
        window.isOpaque = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]

        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.textColor = .black
        field.placeholderString = "Six-digit code"
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Six-digit code")
        window.initialFirstResponder = field

        hosting = NSHostingView(rootView: content())
        hosting.safeAreaRegions = []
        window.contentView = hosting
        fitContent()
    }

    func present() {
        field.stringValue = ""
        field.isEnabled = true
        let workspace = NSWorkspace.shared
        passwordIcon = workspace.urlForApplication(withBundleIdentifier: "com.apple.Passwords")
            .map { workspace.icon(forFile: $0.path) }
        appIcon = NSApp.applicationIconImage
        updateContent()
        window.center()
        focusCodeField()
    }

    func showError(_ text: String?) {
        field.stringValue = ""
        field.isEnabled = true
        updateContent(message: text ?? "Code not accepted. Try again.", isError: true)
        focusCodeField()
        window.perform(NSSelectorFromString("_shake"))
    }

    private func content(message: String? = nil, isError: Bool = false) -> PINView {
        PINView(passwordIcon: passwordIcon, appIcon: appIcon, field: field,
                message: message, isError: isError, cancel: { [weak self] in self?.cancelCode() })
    }

    private func updateContent(message: String? = nil, isError: Bool = false) {
        hosting.rootView = content(message: message, isError: isError)
        fitContent()
    }

    private func fitContent() {
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
    }

    private func focusCodeField() {
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(field)
    }

    func dismiss() {
        field.stringValue = ""
        window.orderOut(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard field.isEnabled else { return }
        let digits = String(field.stringValue.filter { "0123456789".contains($0) }.prefix(6))
        if field.stringValue != digits { field.stringValue = digits }
        if digits.count == 6 { submitCode() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submitCode()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelCode()
            return true
        default:
            return false
        }
    }

    private func submitCode() {
        guard field.isEnabled else { return }
        let pin = field.stringValue
        guard pin.count == 6, pin.allSatisfy({ "0123456789".contains($0) }) else {
            window.perform(NSSelectorFromString("_shake"))
            return
        }
        field.isEnabled = false
        onSubmit?(pin)
    }

    private func cancelCode() {
        dismiss()
        onCancel?()
    }

    func windowWillClose(_ notification: Notification) {
        field.stringValue = ""
        onCancel?()
    }
}
