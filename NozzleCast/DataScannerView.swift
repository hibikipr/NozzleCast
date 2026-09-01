import SwiftUI
import VisionKit

/// Live camera feed shared between barcode and text (label OCR) scanning, backed by
/// VisionKit's on-device DataScannerViewController — no camera/OCR library dependency needed.
/// Only works on a real device with a Neural Engine; the Simulator can't run it at all.
@Observable
final class ScannerBridge {
    var lastBarcode: String?
    var liveText: String = ""

    func reset() {
        lastBarcode = nil
        liveText = ""
    }
}

enum ScannerMode {
    case barcode, text
}

struct DataScannerView: UIViewControllerRepresentable {
    var mode: ScannerMode
    var bridge: ScannerBridge

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let types: Set<DataScannerViewController.RecognizedDataType> = mode == .barcode ? [.barcode()] : [.text()]
        let vc = DataScannerViewController(
            recognizedDataTypes: types,
            qualityLevel: .balanced,
            recognizesMultipleItems: mode == .text,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: mode == .barcode
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: mode, bridge: bridge) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var mode: ScannerMode
        var bridge: ScannerBridge

        init(mode: ScannerMode, bridge: ScannerBridge) {
            self.mode = mode
            self.bridge = bridge
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            apply(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            apply(allItems)
        }

        private func apply(_ items: [RecognizedItem]) {
            switch mode {
            case .barcode:
                guard bridge.lastBarcode == nil else { return }
                for item in items {
                    if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                        bridge.lastBarcode = payload
                        return
                    }
                }
            case .text:
                let lines = items.compactMap { item -> String? in
                    if case .text(let text) = item { return text.transcript }
                    return nil
                }
                bridge.liveText = lines.joined(separator: "\n")
            }
        }
    }
}

/// True on a device that can actually run live camera scanning (real hardware with a
/// Neural Engine, camera access not previously denied). Always false in the Simulator.
enum ScannerAvailability {
    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}
