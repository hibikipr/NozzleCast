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
                        message: "Camera access is off for NozzleCast",
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
                .ncFont(size: 12.5, relativeTo: .caption)
                .foregroundStyle(NCColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .ncFont(size: 12.5, weight: .semibold, relativeTo: .caption)
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
        // Deliberately not starting the session here: makeUIViewController can run before the
        // view is actually attached to a window, and starting the camera before that reliably
        // fails on-device (Fig/RunningBoard needs the view visible). updateUIViewController
        // runs after attachment, so the first start attempt happens there instead.
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // Bounded start: at most one attempt, plus one delayed retry if that attempt fails
        // (the view can still be mid-attachment on the very first pass). Without a cap here,
        // a failed start sets bridge.failureMessage, which re-renders this view, which
        // re-enters here with isScanning still false, retrying the same broken start forever -
        // a tight loop that hammers the capture session rather than surfacing one clear failure.
        guard !uiViewController.isScanning, !context.coordinator.didAttemptStart else { return }
        context.coordinator.didAttemptStart = true
        attemptStart(uiViewController, retriesLeft: 1)
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: mode, bridge: bridge) }

    private func attemptStart(_ vc: DataScannerViewController, retriesLeft: Int) {
        do {
            try vc.startScanning()
        } catch {
            if retriesLeft > 0 {
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    attemptStart(vc, retriesLeft: retriesLeft - 1)
                }
            } else {
                bridge.failureMessage = "Couldn't start the camera: \(error.localizedDescription)"
            }
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var mode: ScannerMode
        var bridge: ScannerBridge
        var didAttemptStart = false

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
