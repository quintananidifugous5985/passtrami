import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, tools, about

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .general: "General"
        case .tools: "Tools"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .tools: .orange
        case .about: .blue
        }
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selection = pane
                    } label: {
                        SettingsSidebarRow(pane: pane, isSelected: selection == pane)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeightChange)
            Spacer()
        }
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pane.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(
                            colors: [pane.color.opacity(0.85), pane.color],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
                .accessibilityHidden(true)
            Text(pane.title)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
