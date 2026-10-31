import SwiftUI

/// How a Monitor-tab printer card pairs the animated printer with the camera snapshot or cover
/// render. Picked from the Monitor header's menu or in Settings; both read and write the same
/// `@AppStorage(PrinterCardLayout.storageKey)` value.
enum PrinterCardLayout: String, CaseIterable, Identifiable {
    /// The original card: one thumbnail that's the camera while printing, the printer otherwise.
    case classic
    /// Two equal tiles above the details — the printer and the camera or cover.
    case twinTiles
    /// A full-width camera or cover with the printer as a chip in its corner.
    case hero
    /// The printer tile with the camera or cover in a corner square; tapping swaps them.
    case pictureInPicture

    static let storageKey = "printerCardLayout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: String(localized: "Classic", comment: "Printer card layout: one thumbnail")
        case .twinTiles: String(localized: "Twin tiles", comment: "Printer card layout: printer and camera side by side")
        case .hero: String(localized: "Hero", comment: "Printer card layout: large camera with a printer chip")
        case .pictureInPicture: String(localized: "Picture in picture", comment: "Printer card layout: camera in the printer tile's corner")
        }
    }

    var systemImage: String {
        switch self {
        case .classic: "rectangle.grid.1x2"
        case .twinTiles: "square.split.2x1"
        case .hero: "photo"
        case .pictureInPicture: "pip"
        }
    }
}
