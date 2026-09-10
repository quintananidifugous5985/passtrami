import SwiftUI

struct CompanionPairingView: View {
    let service: CompanionService
    @Binding var code: String
    @State private var showsScanner = false
    @State private var pairsAfterScanning = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        Form {
            Section {
                Label("Pair with Your Mac", systemImage: "laptopcomputer.and.iphone")
                    .font(.headline)
                    .padding(.vertical, 4)
            } footer: {
                Text("In \(Bundle.main.displayName) on your Mac, open Settings and show the pairing code.")
            }
            if service.accountAvailable {
                Section {
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                        codeFocused = false
                        showsScanner = true
                    }
                    TextField("Pairing code", text: $code)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($codeFocused)
                        .onSubmit { pair() }
                    Button {
                        pair()
                    } label: {
                        HStack {
                            Text("Pair Mac")
                            Spacer()
                            if service.isBusy { ProgressView() }
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isBusy)
                } footer: {
                    Text("Use the same Apple Account on both devices. Passwords stay on your Mac.")
                }
                .disabled(service.isBusy)
            } else {
                Section {
                    Label("iCloud Required", systemImage: "icloud")
                    Button("Retry") { Task { await service.refresh() } }
                        .disabled(service.isBusy)
                } footer: {
                    Text(service.accountMessage ?? String(localized: "Sign in to iCloud in Settings, then try again."))
                }
            }
        }
        .sheet(isPresented: $showsScanner, onDismiss: {
            guard pairsAfterScanning else { return }
            pairsAfterScanning = false
            pair()
        }) {
            CompanionScannerView { scannedCode in
                code = scannedCode
                pairsAfterScanning = true
                showsScanner = false
            }
        }
    }

    private func pair() {
        guard !service.isBusy,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        codeFocused = false
        Task { await service.pair(code: code) }
    }
}
