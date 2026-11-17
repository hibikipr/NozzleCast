import Vision
import UIKit

/// Reads a still photo of a filament label — one picked from the library rather than the live
/// camera — with Vision: its text, top to bottom, and every barcode in it (a box's QR code can
/// carry the EAN its Code 128 barcode doesn't). Same result shape as the live scanner's.
enum LabelImageReader {
    static func read(_ image: UIImage) async -> FilamentLabelReader.Reading {
        guard let cgImage = image.cgImage else { return FilamentLabelReader.Reading(text: "") }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            // Product codes and brand names aren't dictionary words; correction "fixes" them.
            text.usesLanguageCorrection = false
            let barcodes = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            do {
                try handler.perform([text, barcodes])
            } catch {
                // Reads as "nothing found" to the person; the log says why.
                NSLog("NCDEBUG label photo: Vision failed: %@", String(describing: error))
            }

            // Vision's own order, which keeps a block together: a label's "SKU" heading stays next
            // to the value under it rather than beside the "Net weight" in the next column.
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let codes = (barcodes.results ?? []).compactMap(\.payloadStringValue)
            return FilamentLabelReader.Reading(text: lines.joined(separator: "\n"), barcodes: codes)
        }.value
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
