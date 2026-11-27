// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import SwiftUI
import Vision
import VisionKit

/// The camera, looking for one of Lobby's QR codes.
struct QRScannerSheet: View {
    let title: String
    let found: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The sheet is on screen: only then the camera starts.
    @State private var isUp = false
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    ContentUnavailableView(
                        "This device cannot scan codes", systemImage: AppSymbol.scan, description: Text("Type the code instead."))
                } else if access == .authorized {
                    QRScannerView(isUp: isUp, found: found).ignoresSafeArea(edges: .bottom)
                } else if access == .denied || access == .restricted {
                    ContentUnavailableView(
                        "Lobby may not use the camera", systemImage: AppSymbol.scan,
                        description: Text("Allow it in Settings, or type the code instead."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            isUp = true
            guard access == .notDetermined else { return }
            access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
    }
}

private struct QRScannerView: UIViewControllerRepresentable {
    let isUp: Bool
    let found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard isUp, !scanner.isScanning, !context.coordinator.isDone else { return }
        do {
            try scanner.startScanning()
        } catch {
            // Without a camera the sheet says nothing more than its title: Cancel and type.
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (String) -> Void
        private(set) var isDone = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in added {
                guard !isDone, let text = code.payloadStringValue, text.lowercased().hasPrefix("lobby://") else { continue }
                isDone = true
                scanner.stopScanning()
                found(text)
            }
        }
    }
}
