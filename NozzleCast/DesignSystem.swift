import SwiftUI
import UIKit

extension Bundle {
    /// The app's localized display name (falls back to the target name if unset), for
    /// building sentences that reference the app without hardcoding its name inline.
    var displayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "NozzleCast"
    }
}

extension Spool {
    /// The fill for this spool's color swatch — a left-to-right gradient across `colorHex` plus
    /// `extraColorHexes` when set (a dual/multi-color spool), otherwise just the plain color.
    var swatchFill: AnyShapeStyle {
        guard !extraColorHexes.isEmpty else { return AnyShapeStyle(Color(hex: colorHex)) }
        let colors = ([colorHex] + extraColorHexes).map { Color(hex: $0) }
        return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .alphanumerics.inverted)
        if s.count == 6 { s = "FF" + s }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let a = Double((value >> 24) & 0xFF) / 255
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// True if this color reads as light enough that black foreground text has better contrast than white.
    var isLight: Bool {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return false }
        let luminance = 0.299 * components[0] + 0.587 * components[1] + 0.114 * components[2]
        return luminance > 0.6
    }

    /// "#RRGGBB" for this color, in the sRGB space used everywhere else in the app.
    func toHexString() -> String {
        let converted = UIColor(self).cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        guard let components = converted?.components, components.count >= 3 else { return "#808080" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum NCColor {
    static let canvasBackground = Color(hex: "#1a1a1a")
    static let cardFill = Color(hex: "#2d2d2d").opacity(0.55)
    static let cardBorder = Color.white.opacity(0.08)
    static let well = Color(hex: "#111111")
    static let wellAlt = Color(hex: "#141414")
    /// `well` is close enough to black that a dark-housing printer render (the H2C, notably)
    /// nearly disappears into it. Printer thumbnails use this instead — lighter fill plus a
    /// visible border, so the container reads clearly regardless of how dark the image is.
    static let printerWell = Color(hex: "#242424")
    static let printerWellBorder = Color.white.opacity(0.14)

    static let textPrimary = Color.white
    static let textSecondary = Color(red: 235.0 / 255, green: 235.0 / 255, blue: 245.0 / 255).opacity(0.6)
    static let textTertiary = Color(red: 235.0 / 255, green: 235.0 / 255, blue: 245.0 / 255).opacity(0.45)

    static let accent = Color(hex: "#2A5FCC")
    static let accentLight = Color(hex: "#4F7FE0")
    static let accentDark = Color(hex: "#1E48A8")

    static let statusPrinting = Color(hex: "#22C55E")
    static let statusWarning = Color(hex: "#F59E0B")
    static let statusError = Color(hex: "#EF4444")
    static let statusOffline = Color(hex: "#6B6B6B")
    static let statusOfflineDark = Color(hex: "#4A4A4A")

    static let destructive = Color(hex: "#EF4444")

    static let settingsBackground = Color(hex: "#1C1C1E")
    static let settingsSeparator = Color(red: 84.0 / 255, green: 84.0 / 255, blue: 88.0 / 255).opacity(0.55)

    static let segmentTrack = Color(red: 120.0 / 255, green: 120.0 / 255, blue: 128.0 / 255).opacity(0.24)
    static let segmentThumb = Color(hex: "#6B6B70")
}

/// Glass surface used for cards, floating pills, and sheets throughout the app.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(NCColor.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(NCColor.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    func sectionEyebrow() -> some View {
        self
            .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
            .tracking(0.6)
            .foregroundStyle(NCColor.textSecondary)
            .textCase(.uppercase)
    }
}

extension PrinterState {
    var color: Color {
        switch self {
        case .printing: NCColor.statusPrinting
        case .paused: NCColor.statusWarning
        case .idle: NCColor.statusOffline
        case .error: NCColor.statusError
        case .offline: NCColor.statusOfflineDark
        }
    }

    var label: String {
        switch self {
        case .printing: String(localized: "Printing", comment: "Printer status")
        case .paused: String(localized: "Paused", comment: "Printer status")
        case .idle: String(localized: "Idle", comment: "Printer status")
        case .error: String(localized: "Error", comment: "Printer status")
        case .offline: String(localized: "Offline", comment: "Printer status")
        }
    }

    var pulses: Bool { self == .printing }
}
