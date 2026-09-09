import AppKit

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
    private let field = NSSecureTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()

    override init() {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel]
        if #available(macOS 27.0, *) { styleMask.insert(.asterGlass) }
        window = PINPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                          styleMask: styleMask,
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Unlock Aster"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        window.initialFirstResponder = field
        message.maximumNumberOfLines = 3
        message.preferredMaxLayoutWidth = 312
        message.isHidden = true
        field.placeholderString = "Six-digit code"
        field.font = .monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        field.delegate = self
        field.setAccessibilityLabel("Six-digit code")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCode))
        cancel.bezelStyle = .glass
        cancel.controlSize = .large
        cancel.tintProminence = .primary
        cancel.keyEquivalent = "\u{1b}"
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, cancel])
        buttons.spacing = 8
        for view in [field, message, buttons] { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.widthAnchor.constraint(equalToConstant: 312),
                field.widthAnchor.constraint(equalTo: stack.widthAnchor),
                message.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        fitContent()
    }

    func present() {
        field.stringValue = ""
        field.isEnabled = true
        message.stringValue = ""
        message.isHidden = true
        fitContent()
        window.center()
        focusCodeField()
    }

    func showError(_ text: String?) {
        field.stringValue = ""
        field.isEnabled = true
        message.stringValue = text ?? "Code not accepted. Try again."
        message.textColor = .systemRed
        message.isHidden = false
        fitContent()
        focusCodeField()
    }

    private func fitContent() {
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 360, height: stack.fittingSize.height + 48))
    }

    private func focusCodeField() {
        // The panel takes keyboard focus without activating the menu bar app.
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

    private func submitCode() {
        guard field.isEnabled else { return }
        let pin = field.stringValue
        guard pin.count == 6, pin.allSatisfy({ "0123456789".contains($0) }) else { return }
        field.stringValue = ""
        field.isEnabled = false
        message.stringValue = "Checking…"
        message.textColor = .secondaryLabelColor
        message.isHidden = false
        fitContent()
        onSubmit?(pin)
    }

    @objc private func cancelCode() {
        dismiss()
        onCancel?()
    }

    func windowWillClose(_ notification: Notification) {
        field.stringValue = ""
        onCancel?()
    }
}
