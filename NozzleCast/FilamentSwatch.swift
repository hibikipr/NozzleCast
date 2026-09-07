import SwiftUI
import NozzleCastShared

extension Spool {
    /// Bambuddy-style color swatch for this spool — checkerboard-backed, gradient/multicolor
    /// aware, with any finish overlay applied. Wrap in `.frame` and `.clipShape` at the call
    /// site, same as the plain `Shape().fill(...)` pattern this replaces.
    var swatch: FilamentSwatchView {
        FilamentSwatchView(colorHex: colorHex, alpha: colorAlpha, extraColorHexes: extraColorHexes, subtype: subtype, effectType: effectType)
    }
}

#Preview {
    let spools = MockData.makeSpools()
    HStack(spacing: 12) {
        ForEach(spools) { spool in
            spool.swatch
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
    .padding()
    .background(.black)
}
