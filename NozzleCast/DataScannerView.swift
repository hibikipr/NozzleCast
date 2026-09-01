import SwiftUI
import VisionKit
import AVFoundation

/// Live camera feed shared between barcode and text (label OCR) scanning, backed by
/// VisionKit's on-device DataScannerViewController — no camera/OCR library dependency needed.
/// Only works on a real device with a Neural Engine; the Simulator can't run it at all.
@Observable
final class ScannerBridge {
    var lastBarcode: String?
    var liveText: String = ""
    /// Set if the capture session fails or dies after starting (e.g. hardware claimed
    /// elsewhere, torn down mid-session) — surfaced by the UI instead of a silent black screen.
    var failureMessage: String?

    func reset() {
        lastBarcode = nil
        liveText = ""
        failureMessage = nil
    }
}

enum ScannerMode {
    case barcode, text
}

/// Wraps DataScannerView with explicit camera-permission handling. `DataScannerViewController
/// .isAvailable` reflects *current* authorization and reads false before permission has ever
/// been requested — relying on it alone means the camera view never appears and the system
/// permission prompt never fires. This checks/requests authorization itself first, so a first
/// launch actually prompts instead of silently falling back to "needs a real device".
struct ScannerCameraGate: View {
    var mode: ScannerMode
    var bridge: ScannerBridge

    @State private var authStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if !DataScannerViewController.isSupported {
                unavailable(
                    icon: "camera.metering.unknown",
                    message: "Camera scanning needs a real device"
                )
            } else {
                switch authStatus {
                case .authorized:
                    if DataScannerViewController.isAvailable {
                        DataScannerView(mode: mode, bridge: bridge)
                    } else {
                        unavailable(icon: "camera.metering.unknown", message: "Camera unavailable right now")
                    }
                case .notDetermined:
                    Color.clear
                        .task {
                            let granted = await AVCaptureDevice.requestAccess(for: .video)
                            authStatus = granted ? .authorized : .denied
                        }
                case .denied, .restricted:
                    unavailable(
                        icon: "camera.fill",
                        message: "Camera access is off for NoozleCast",
                        actionTitle: "Open Settings"
                    ) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                @unknown default:
                    unavailable(icon: "camera.fill", message: "Camera unavailable")
                }
            }
        }
        .onAppear { authStatus = AVCaptureDevice.authorizationStatus(for: .video) }
    }

    @ViewBuilder
    private func unavailable(icon: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(NCColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NCColor.accentLight)
            }
        }
    }
}

private struct DataScannerView: UIViewControllerRepresentable {
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
        startScanning(vc)
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if !uiViewController.isScanning {
            startScanning(uiViewController)
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: mode, bridge: bridge) }

    private func startScanning(_ vc: DataScannerViewController) {
        do {
            try vc.startScanning()
        } catch {
            bridge.failureMessage = "Couldn't start the camera: \(error.localizedDescription)"
        }
    }

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

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            bridge.failureMessage = "Scanning stopped: \(error.localizedDescription)"
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
/// Neural Engine). Always false in the Simulator. Doesn't reflect camera permission —
/// use `ScannerCameraGate`, which handles that explicitly.
enum ScannerAvailability {
    static var isSupported: Bool {
        DataScannerViewController.isSupported
    }
}
