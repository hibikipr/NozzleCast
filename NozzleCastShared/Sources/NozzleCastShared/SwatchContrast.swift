import Foundation

/// Which of the two text tones reads on a given filament swatch.
public enum SwatchForeground: Equatable, Sendable {
    case dark
    case light
}

/// Picks a label colour for text drawn directly on a filament swatch.
///
/// The AMS widget used to put its material label on a translucent black band pinned to the bottom
/// of each swatch. The band was doing two unhelpful things at once: hiding the lower quarter of a
/// pill whose colour is the entire point of the widget, and still not guaranteeing contrast — on a
/// black swatch, white text over 45%-black over black is barely visible. Deriving the tone from
/// the swatch instead lets the label sit on the colour with nothing between them.
public enum SwatchContrast {
    /// What sits *behind* the colour layer inside the swatch — and it is not the widget canvas.
    /// `FilamentSwatchView` draws a checkerboard base unconditionally and composites the colour
    /// over it, so a translucent spool reads as genuinely clear rather than as a muddy tint. That
    /// checkerboard alternates `white 0.96` and `white 0.59` in equal measure, so its mean is what
    /// alpha blends toward.
    ///
    /// Getting this wrong is not academic: composited against the near-black canvas instead, a
    /// 20%-alpha swatch measures dark and gets white text — which then sits on a pale checkerboard
    /// and disappears. Caught by rendering the widget rather than by reading the code.
    private static let checkerboardMean = (0.96 + 0.59) / 2
    private static let underlayComponents = (r: checkerboardMean, g: checkerboardMean, b: checkerboardMean)

    public static func preferredForeground(
        colorHex: String?,
        alpha: Double = 1,
        extraColorHexes: [String] = []
    ) -> SwatchForeground {
        // No colour to measure: an empty slot is a faint outline on the dark canvas, and a
        // malformed hex is not worth guessing about. Light text is right for the canvas either way.
        guard let base = components(from: colorHex) else { return .light }

        // A multi-colour spool paints several colours across one pill, so the label answers to
        // their combined brightness rather than to whichever was listed first.
        let all = [base] + extraColorHexes.compactMap(components(from:))
        let mixed = (
            r: all.map(\.r).reduce(0, +) / Double(all.count),
            g: all.map(\.g).reduce(0, +) / Double(all.count),
            b: all.map(\.b).reduce(0, +) / Double(all.count)
        )

        let clampedAlpha = min(max(alpha, 0), 1)
        let composited = (
            r: mixed.r * clampedAlpha + underlayComponents.r * (1 - clampedAlpha),
            g: mixed.g * clampedAlpha + underlayComponents.g * (1 - clampedAlpha),
            b: mixed.b * clampedAlpha + underlayComponents.b * (1 - clampedAlpha)
        )

        // WCAG relative luminance, not a channel average: pure green is far brighter to the eye
        // than pure blue at the same numeric value, and averaging calls both mid-grey.
        let luminance = 0.2126 * linear(composited.r)
            + 0.7152 * linear(composited.g)
            + 0.0722 * linear(composited.b)

        // Compare actual contrast ratios against each candidate rather than thresholding
        // luminance at an arbitrary midpoint — the crossover between them is nearer 0.18 than 0.5.
        let againstBlack = (luminance + 0.05) / 0.05
        let againstWhite = 1.05 / (luminance + 0.05)
        return againstBlack >= againstWhite ? .dark : .light
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func components(from hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex else { return nil }
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.removeAll { $0 == "#" }
        // AppStore writes 6-digit hex, but Bambu's own tray colours arrive 8-digit (RRGGBBAA) and
        // that trailing pair must not be read as part of the blue channel.
        guard cleaned.count == 6 || cleaned.count == 8,
              cleaned.allSatisfy(\.isHexDigit),
              let value = UInt64(cleaned.prefix(6), radix: 16)
        else { return nil }
        return (
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }
}
