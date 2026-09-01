import SwiftUI

/// The app's typography is expressed as fixed point sizes throughout (matching the design
/// system's pixel-precise tokens), but `.font(.system(size:))` never responds to the user's
/// Text Size / Larger Text accessibility setting - only text styles (`.body`, `.title`, ...)
/// or a `@ScaledMetric`-derived size do. This scales a fixed size against that setting while
/// preserving the design's relative type hierarchy, without switching every label over to the
/// system's built-in styles (which would lose the specific sizes/weights the design calls for).
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo textStyle: Font.TextStyle) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: weight, design: design))
    }
}

extension View {
    /// Drop-in replacement for `.font(.system(size:weight:))` on text labels that scales with
    /// the user's Dynamic Type setting. `relativeTo` should be the built-in text style whose
    /// base size is closest to `size` - that's what Apple's scaling curve for `textStyle` is
    /// tuned around, so picking the closest one keeps the scaling feeling proportionate.
    func ncFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, relativeTo textStyle: Font.TextStyle = .body) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, relativeTo: textStyle))
    }
}
