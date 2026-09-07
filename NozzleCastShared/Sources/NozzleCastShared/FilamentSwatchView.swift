import SwiftUI

/// Renders a spool's color swatch the way Bambuddy's own Filament tab does: a checkerboard base
/// (so a translucent spool reads as actually clear instead of a flat, muddy tint), a color layer
/// — solid, a smooth diagonal blend, a hard-edge split, or a conic "pie" wheel for a Bambu
/// `Multicolor` spool — and an optional finish overlay matching Bambuddy's `effect_type`.
public struct FilamentSwatchView: View {
    public var colorHex: String
    public var alpha: Double
    public var extraColorHexes: [String]
    public var subtype: String?
    public var effectType: String?

    public init(colorHex: String, alpha: Double = 1, extraColorHexes: [String] = [], subtype: String? = nil, effectType: String? = nil) {
        self.colorHex = colorHex
        self.alpha = alpha
        self.extraColorHexes = extraColorHexes
        self.subtype = subtype
        self.effectType = effectType
    }

    public var body: some View {
        Canvas { context, size in
            Self.drawCheckerboard(&context, size: size)
            Self.drawColorLayer(&context, size: size, colorHex: colorHex, alpha: alpha, extraColorHexes: extraColorHexes, subtype: subtype, effectType: effectType)
            Self.drawEffectOverlay(&context, size: size, colorHex: colorHex, extraColorHexes: extraColorHexes, subtype: subtype, effectType: effectType)
        }
    }

    // MARK: - Checkerboard base

    private static let checkerLight = Color(white: 0.96)
    private static let checkerDark = Color(white: 0.59)
    private static let checkerCell: CGFloat = 6

    private static func drawCheckerboard(_ context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(checkerLight))
        var row = 0
        var y: CGFloat = 0
        while y < size.height {
            var col = 0
            var x: CGFloat = 0
            while x < size.width {
                if (row + col).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x, y: y, width: checkerCell, height: checkerCell)), with: .color(checkerDark))
                }
                x += checkerCell
                col += 1
            }
            y += checkerCell
            row += 1
        }
    }

    // MARK: - Color layer

    private static func resolvedColors(colorHex: String, extraColorHexes: [String], alpha: Double) -> [Color] {
        ([colorHex] + extraColorHexes).map { hex in
            let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            return Color(hex: String(clean.prefix(6))).opacity(alpha)
        }
    }

    private static func isMulticolor(subtype: String?, effectType: String?) -> Bool {
        subtype?.caseInsensitiveCompare("Multicolor") == .orderedSame || effectType?.lowercased() == "multicolor"
    }

    private static func isHardSplit(effectType: String?) -> Bool {
        let e = effectType?.lowercased()
        return e == "dual-color" || e == "tri-color"
    }

    private static func hardEdgeStops(_ colors: [Color]) -> [Gradient.Stop] {
        let n = colors.count
        guard n > 0 else { return [] }
        return colors.enumerated().flatMap { i, color in
            [Gradient.Stop(color: color, location: Double(i) / Double(n)),
             Gradient.Stop(color: color, location: min(Double(i + 1) / Double(n), 1))]
        }
    }

    private static func drawColorLayer(
        _ context: inout GraphicsContext, size: CGSize, colorHex: String, alpha: Double,
        extraColorHexes: [String], subtype: String?, effectType: String?
    ) {
        let path = Path(CGRect(origin: .zero, size: size))
        let colors = resolvedColors(colorHex: colorHex, extraColorHexes: extraColorHexes, alpha: alpha)

        guard colors.count > 1 else {
            context.fill(path, with: .color(colors.first ?? Color(white: 0.5).opacity(alpha)))
            return
        }

        if isMulticolor(subtype: subtype, effectType: effectType) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(path, with: .conicGradient(Gradient(stops: hardEdgeStops(colors)), center: center, angle: .degrees(0)))
        } else if isHardSplit(effectType: effectType) {
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(stops: hardEdgeStops(colors)),
                    startPoint: CGPoint(x: 0, y: size.height / 2),
                    endPoint: CGPoint(x: size.width, y: size.height / 2)
                )
            )
        } else {
            context.fill(
                path,
                with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height))
            )
        }
    }

    // MARK: - Finish overlays

    private static func drawEffectOverlay(
        _ context: inout GraphicsContext, size: CGSize, colorHex: String,
        extraColorHexes: [String], subtype: String?, effectType: String?
    ) {
        guard let effect = effectType?.lowercased() else { return }
        switch effect {
        case "sparkle":
            drawSparkle(&context, size: size, seed: colorHex + extraColorHexes.joined() + (subtype ?? "") + effect)
        case "wood":
            drawWoodGrain(&context, size: size)
        case "marble":
            drawMarbleSwirls(&context, size: size)
        case "glow":
            drawGlow(&context, size: size)
        case "matte":
            drawMatteInset(&context, size: size)
        case "silk":
            drawSheen(&context, size: size, peakOpacity: 0.30)
        case "galaxy":
            drawSheen(&context, size: size, peakOpacity: 0.40)
        case "metal":
            drawBrushedMetal(&context, size: size)
        default:
            break
        }
    }

    private static func drawWoodGrain(_ context: inout GraphicsContext, size: CGSize) {
        var x: CGFloat = 0
        while x < size.width {
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.black.opacity(0.18)))
            context.fill(Path(CGRect(x: x + 6, y: 0, width: 1, height: size.height)), with: .color(.black.opacity(0.08)))
            x += 12
        }
    }

    private static func drawMarbleSwirls(_ context: inout GraphicsContext, size: CGSize) {
        drawDiagonalStripes(&context, size: size, angleDegrees: 135, color: .white.opacity(0.14), spacing: 14, width: 2)
        drawDiagonalStripes(&context, size: size, angleDegrees: 45, color: .black.opacity(0.10), spacing: 18, width: 2)
    }

    private static func drawDiagonalStripes(
        _ context: inout GraphicsContext, size: CGSize, angleDegrees: Double, color: Color, spacing: CGFloat, width: CGFloat
    ) {
        let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
        context.drawLayer { layer in
            layer.translateBy(x: size.width / 2, y: size.height / 2)
            layer.rotate(by: .degrees(angleDegrees))
            var offset = -diagonal
            while offset < diagonal {
                layer.fill(Path(CGRect(x: offset, y: -diagonal, width: width, height: diagonal * 2)), with: .color(color))
                offset += spacing
            }
        }
    }

    private static func drawGlow(_ context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let gradient = Gradient(stops: [
            .init(color: .white.opacity(0.35), location: 0),
            .init(color: .white.opacity(0), location: 0.7),
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: max(size.width, size.height) / 2)
        )
    }

    private static func drawMatteInset(_ context: inout GraphicsContext, size: CGSize) {
        let gradient = Gradient(stops: [
            .init(color: .black.opacity(0.10), location: 0),
            .init(color: .black.opacity(0), location: 0.5),
            .init(color: .black.opacity(0.10), location: 1),
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(gradient, startPoint: CGPoint(x: size.width / 2, y: 0), endPoint: CGPoint(x: size.width / 2, y: size.height))
        )
    }

    private static func drawSheen(_ context: inout GraphicsContext, size: CGSize, peakOpacity: Double) {
        let gradient = Gradient(stops: [
            .init(color: .white.opacity(0), location: 0.3),
            .init(color: .white.opacity(peakOpacity), location: 0.5),
            .init(color: .white.opacity(0), location: 0.7),
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: size.height * 0.15),
                endPoint: CGPoint(x: size.width, y: size.height * 0.85)
            )
        )
    }

    private static func drawBrushedMetal(_ context: inout GraphicsContext, size: CGSize) {
        var x: CGFloat = 0
        while x < size.width {
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.10)))
            x += 3
        }
        let gradient = Gradient(stops: [
            .init(color: .white.opacity(0.18), location: 0),
            .init(color: .black.opacity(0.18), location: 1),
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(gradient, startPoint: CGPoint(x: size.width / 2, y: 0), endPoint: CGPoint(x: size.width / 2, y: size.height))
        )
    }

    private static func drawSparkle(_ context: inout GraphicsContext, size: CGSize, seed: String) {
        var rng = Mulberry32(seed: fnv1a32(seed))
        let maxDim = max(size.width, size.height)
        for _ in 0..<10 {
            let x = rng.nextDouble() * size.width
            let y = rng.nextDouble() * size.height
            let radius = (0.03 + rng.nextDouble() * 0.05) * maxDim
            let fleck = Color(red: 1, green: 0.97, blue: 0.86)
            let gradient = Gradient(stops: [
                .init(color: fleck.opacity(0.9), location: 0),
                .init(color: fleck.opacity(0), location: 1),
            ])
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(gradient, center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius)
            )
        }
    }

    private static func fnv1a32(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    private struct Mulberry32 {
        private var state: UInt32
        init(seed: UInt32) { state = seed }

        mutating func nextDouble() -> Double {
            state = state &+ 0x6D2B_79F5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            let inner = (t ^ (t >> 7)) &* (t | 61)
            t = (t &+ inner) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }
}

private extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0 == "#" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
