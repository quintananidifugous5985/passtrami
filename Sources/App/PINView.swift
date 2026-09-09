import AppKit
import SwiftUI

struct PINView: View {
    let passwordIcon: NSImage?
    let appIcon: NSImage
    let field: NSTextField
    let message: String?
    let isError: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PINAppIcons(passwordIcon: passwordIcon, appIcon: appIcon)
                .padding(.top, 8)
                .padding(.horizontal, 8)
            PINInstructions(message: message, isError: isError)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            PINControls(field: field, cancel: cancel)
        }
        .padding(16)
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PINAppIcons: View {
    let passwordIcon: NSImage?
    let appIcon: NSImage

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let passwordIcon {
                Image(nsImage: passwordIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 45, height: 45)
            }
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 45 * 0.53, height: 45 * 0.53)
                .offset(x: 7)
        }
        .frame(width: 45, height: 45)
        .accessibilityHidden(true)
    }
}

private struct PINInstructions: View {
    let message: String?
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Unlock Aster")
                .font(.headline)
            if let message {
                Text(message)
                    .foregroundStyle(isError ? .red : .secondary)
            } else {
                Text("Enter the code shown by Passwords to continue.")
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PINControls: View {
    let field: NSTextField
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            PINFieldView(field: field)
                .frame(height: 28)
            Button(action: cancel) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
    }
}

private struct PINFieldView: NSViewRepresentable {
    let field: NSTextField

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 5
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: field.intrinsicContentSize.height)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
