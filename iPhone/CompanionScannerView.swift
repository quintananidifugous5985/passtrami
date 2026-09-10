import AVFoundation
import SwiftUI
import VisionKit

struct CompanionScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if ready {
                    CompanionQRScanner(onCode: onCode, onFailure: {
                        ready = false
                        message = String(localized: "The camera is not available. Enter the pairing code instead.")
                    })
                    .ignoresSafeArea(edges: .bottom)
                } else if let message {
                    ContentUnavailableView("Camera Unavailable", systemImage: "camera",
                                           description: Text(message))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .task { await prepareCamera() }
        }
    }

    private func prepareCamera() async {
        guard DataScannerViewController.isSupported else {
            message = String(localized: "Enter the pairing code shown on your Mac.")
            return
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard !Task.isCancelled else { return }
        if authorized && DataScannerViewController.isAvailable {
            ready = true
        } else {
            message = String(localized: "Allow camera access in Settings, or enter the pairing code instead.")
        }
    }
}

private struct CompanionQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                   recognizesMultipleItems: false,
                                                   isHighFrameRateTrackingEnabled: false,
                                                   isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() }
        catch { Task { @MainActor in onFailure() } }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private let onFailure: () -> Void
        private var completed = false

        init(onCode: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !completed else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item, let value = barcode.payloadStringValue else { continue }
                completed = true
                dataScanner.stopScanning()
                onCode(value)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            dataScanner.stopScanning()
            onFailure()
        }
    }
}
