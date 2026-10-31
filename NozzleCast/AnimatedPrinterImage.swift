import SwiftUI

/// A printer's model image, animated by what it's doing: the toolhead travels and a part grows on
/// the plate while printing, the status light and display take the status colour, a failed print
/// gives a short shake, and an offline printer greys out.
///
/// The model's own drawing stays underneath. On top of it, a patch in the chamber's flat colour
/// hides the toolhead where it's drawn, and a copy of that same toolhead — cut from the image
/// itself — moves along the rail; the light strip and display are repainted in the status
/// colour. So every model keeps its real artwork, and the only per-model data is where those
/// parts sit (`PrinterArtGeometry`), measured from the 640x640 assets.
///
/// With Reduce Motion on it keeps each status's pose and colours but doesn't move.
struct AnimatedPrinterImage: View {
    var assetName: String
    var state: PrinterState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let geometry = PrinterArtGeometry.forAsset(assetName) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !state.isAnimated)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let pose = PrinterPose(state: state, time: time, animated: !reduceMotion)
                GeometryReader { proxy in
                    let scale = min(proxy.size.width, proxy.size.height) / PrinterArtGeometry.canvas
                    PrinterArtLayers(assetName: assetName, geometry: geometry, pose: pose, scale: scale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .saturation(state == .offline ? 0 : 1)
            .opacity(state == .offline ? 0.5 : 1)
            .accessibilityHidden(true)
        } else {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

private extension PrinterState {
    /// States with continuous motion; the rest are drawn once and the timeline is paused.
    var isAnimated: Bool {
        switch self {
        case .printing, .paused, .finished, .failed: true
        case .idle, .offline: false
        }
    }
}

/// Where each part of a model's image sits, in the asset's 640x640 pixel space.
struct PrinterArtGeometry {
    static let canvas: CGFloat = 640

    enum Kind {
        /// Enclosed printers: toolhead(s) on a horizontal rail inside the chamber window.
        case enclosed
        /// Open-frame printers (A1, A2L): the carriage rides a vertical post above the bed.
        case openFrame
    }

    var kind: Kind
    /// The toolhead(s) as drawn — what gets hidden and then moved.
    var heads: [CGRect]
    /// How far the heads may travel from where they're drawn (x for a rail, y for a post).
    var travel: ClosedRange<CGFloat>
    /// The rail (enclosed) or post (open frame) to redraw through the hidden head.
    var rail: CGRect
    /// The flat colour behind the head: the chamber window, or nothing (`nil`, open frame).
    var windowColor: Color?
    var railColor: Color
    /// The side status light (the AMS lite on an open frame) and the colour beneath it.
    var strip: CGRect
    var stripBase: Color
    /// The display's lit strip (none on an open frame) and the display behind it.
    var screen: CGRect?
    var screenBase: Color
    /// Where the printed part stands: centred on `partCenterX`, growing up from `floorY`.
    var partCenterX: CGFloat
    var floorY: CGFloat
    var partSize: CGSize

    static func forAsset(_ name: String) -> PrinterArtGeometry? {
        switch name {
        case "PrinterH2C": wide(heads: [CGRect(x: 289, y: 258, width: 36, height: 46)], strip: CGRect(x: 588, y: 212, width: 12, height: 140), greyBody: true)
        case "PrinterH2S": wide(heads: [CGRect(x: 289, y: 258, width: 36, height: 46)], strip: CGRect(x: 589, y: 213, width: 10, height: 138), greyBody: false)
        case "PrinterH2D": wide(heads: [CGRect(x: 207, y: 258, width: 33, height: 46), CGRect(x: 382, y: 258, width: 32, height: 46)],
                                strip: CGRect(x: 589, y: 213, width: 10, height: 138), greyBody: false)
        case "PrinterP1S", "PrinterP2S", "PrinterX1C", "PrinterX2D": narrow(strip: CGRect(x: 539, y: 213, width: 10, height: 138), greyBody: false)
        case "PrinterX1E": narrow(strip: CGRect(x: 538, y: 212, width: 12, height: 140), greyBody: true)
        case "PrinterP1P": p1p
        case "PrinterA1": openFrame(strip: CGRect(x: 551, y: 381, width: 70, height: 32))
        case "PrinterA2L": openFrame(strip: CGRect(x: 591, y: 381, width: 49, height: 32))
        default: nil
        }
    }

    /// The P1P's open sides are drawn as a light-grey chamber.
    private static var p1p: PrinterArtGeometry {
        var geometry = narrow(strip: CGRect(x: 539, y: 213, width: 10, height: 138), greyBody: false)
        geometry.heads = [CGRect(x: 295, y: 257, width: 36, height: 48)]
        geometry.windowColor = Color(hex: "#8B8F96")
        geometry.railColor = Color(hex: "#979EA8")
        return geometry
    }

    /// H2-series: a 500px-wide chamber, rail from x 88 to 551.
    private static func wide(heads: [CGRect], strip: CGRect, greyBody: Bool) -> PrinterArtGeometry {
        enclosed(heads: heads, railX: 88...551, windowX: 69...570, screenX: 61, strip: strip, greyBody: greyBody)
    }

    /// P-, X1- and X2-series: a 400px-wide chamber, rail from x 138 to 501.
    private static func narrow(strip: CGRect, greyBody: Bool) -> PrinterArtGeometry {
        enclosed(heads: [CGRect(x: 295, y: 258, width: 36, height: 46)], railX: 138...501, windowX: 119...520,
                 screenX: 111, strip: strip, greyBody: greyBody)
    }

    private static func enclosed(heads: [CGRect], railX: ClosedRange<CGFloat>, windowX: ClosedRange<CGFloat>,
                                 screenX: CGFloat, strip: CGRect, greyBody: Bool) -> PrinterArtGeometry {
        let left = heads.map(\.minX).min()!, right = heads.map(\.maxX).max()!
        let margin: CGFloat = 8
        return PrinterArtGeometry(
            kind: .enclosed,
            heads: heads,
            travel: (railX.lowerBound + margin - left)...(railX.upperBound - margin - right),
            rail: CGRect(x: railX.lowerBound, y: 275, width: railX.upperBound - railX.lowerBound, height: 12),
            // The grey-bodied models (H2C, X1E) draw a slightly darker chamber and rail.
            windowColor: Color(hex: greyBody ? "#414751" : "#484D56"),
            railColor: Color(hex: greyBody ? "#888F9A" : "#89909B"),
            strip: strip,
            stripBase: Color(hex: greyBody ? "#9AA1AD" : "#EDEFF3"),
            screen: CGRect(x: screenX, y: 127, width: 82, height: 11),
            screenBase: Color(hex: "#3A3F49"),
            partCenterX: (windowX.lowerBound + windowX.upperBound) / 2,
            floorY: 478,
            partSize: CGSize(width: 88, height: 96)
        )
    }

    /// A1 and A2L: the carriage rides the post between y 150 and 290; the bed's top is y 487.
    private static func openFrame(strip: CGRect) -> PrinterArtGeometry {
        let carriage = CGRect(x: 270, y: 200, width: 100, height: 110)
        return PrinterArtGeometry(
            kind: .openFrame,
            heads: [carriage],
            travel: (150 - carriage.midY)...(290 - carriage.midY),
            rail: CGRect(x: 310, y: 96, width: 20, height: 251),
            windowColor: nil,
            railColor: Color(hex: "#9AA1AD"),
            strip: strip,
            stripBase: Color(hex: "#2C5AB9"),
            screen: nil,
            screenBase: .clear,
            partCenterX: 320,
            floorY: 486,
            partSize: CGSize(width: 70, height: 80)
        )
    }
}

/// One frame of the animation: where the parts are and what colour the lights are.
struct PrinterPose {
    /// 0...1 along the head's travel.
    var headPosition: CGFloat
    /// 0...1 of the part's full height.
    var partHeight: CGFloat
    var partScale: CGFloat = 1
    /// 0...1 of the display strip lit.
    var screenFill: CGFloat
    var lightColor: Color
    var lightOpacity: Double
    var screenOpacity: Double
    var shakeX: CGFloat = 0

    init(state: PrinterState, time: TimeInterval, animated: Bool) {
        func wave(_ period: Double) -> Double { (1 - cos(time / period * 2 * .pi)) / 2 } // 0...1
        func ramp(_ period: Double, until: Double = 0.88) -> Double { min(time.truncatingRemainder(dividingBy: period) / period / until, 1) }
        func blink(_ period: Double) -> Double { time.truncatingRemainder(dividingBy: period) < period / 2 ? 1 : 0.15 }

        switch state {
        case .printing:
            headPosition = animated ? wave(5.2) : 0.5
            partHeight = animated ? 0.08 + 0.92 * ramp(9) : 0.6
            screenFill = animated ? 0.08 + 0.92 * ramp(9) : 0.6
            lightColor = NCColor.accent
            lightOpacity = animated ? 0.4 + 0.6 * (1 - wave(1.8)) : 1
            screenOpacity = 1
        case .paused:
            headPosition = 0
            partHeight = 0.45
            screenFill = 0.45
            lightColor = NCColor.statusWarning
            lightOpacity = animated ? 0.25 + 0.75 * (1 - wave(2.4)) : 1
            screenOpacity = animated ? blink(1.2) : 1
        case .idle:
            headPosition = 0.5
            partHeight = 0
            screenFill = 1
            lightColor = Color(hex: "#6B6B70")
            lightOpacity = 1
            screenOpacity = 1
        case .finished:
            headPosition = 1
            partHeight = 1
            screenFill = 1
            lightColor = NCColor.accentLight
            lightOpacity = 1
            screenOpacity = 1
            if animated {
                // A small pop once every 3.2s.
                let phase = time.truncatingRemainder(dividingBy: 3.2) / 3.2
                partScale = phase > 0.72 && phase < 0.92 ? 1 + 0.08 * sin((phase - 0.72) / 0.2 * .pi) : 1
            }
        case .failed:
            headPosition = 0.62
            partHeight = 0.37
            screenFill = 1
            lightColor = NCColor.statusError
            lightOpacity = animated ? blink(0.8) : 1
            screenOpacity = lightOpacity
            if animated {
                // A short shake at the start of every 3s.
                let phase = time.truncatingRemainder(dividingBy: 3)
                shakeX = phase < 0.24 ? 4 * sin(phase / 0.24 * 3 * .pi) * (1 - phase / 0.24) : 0
            }
        case .offline:
            headPosition = 0.5
            partHeight = 0
            screenFill = 0
            lightColor = Color(hex: "#3C404A")
            lightOpacity = 1
            screenOpacity = 1
        }
    }
}

/// The model image with the animated parts drawn over it, laid out in the asset's pixel space
/// multiplied by `scale`.
private struct PrinterArtLayers: View {
    var assetName: String
    var geometry: PrinterArtGeometry
    var pose: PrinterPose
    var scale: CGFloat

    private var canvas: CGFloat { PrinterArtGeometry.canvas }
    private var headOffset: CGFloat {
        geometry.travel.lowerBound + (geometry.travel.upperBound - geometry.travel.lowerBound) * pose.headPosition
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The image with its drawn heads covered — one compositing group, so the open
            // frame's punch-out erases the image itself rather than nothing.
            ZStack(alignment: .topLeading) {
                Image(assetName)
                    .resizable()
                    .frame(width: canvas * scale, height: canvas * scale)
                hideDrawnHeads
            }
            .compositingGroup()

            part

            // The heads, cut from the image where they're drawn and moved along the rail/post.
            ForEach(Array(geometry.heads.enumerated()), id: \.offset) { _, head in
                Image(assetName)
                    .resizable()
                    .frame(width: canvas * scale, height: canvas * scale)
                    .mask(alignment: .topLeading) { box(head, Color.black, cornerRatio: 0) }
                    .offset(geometry.kind == .enclosed
                            ? CGSize(width: headOffset * scale, height: 0)
                            : CGSize(width: 0, height: headOffset * scale))
            }

            box(geometry.strip, geometry.stripBase, cornerRatio: 0.5)
            box(geometry.strip, pose.lightColor.opacity(pose.lightOpacity), cornerRatio: 0.5)

            if let screen = geometry.screen {
                box(screen, geometry.screenBase, cornerRatio: 0.45)
                box(CGRect(x: screen.minX, y: screen.minY, width: screen.width * pose.screenFill, height: screen.height),
                    pose.lightColor.opacity(pose.screenOpacity), cornerRatio: 0.45)
            }
        }
        .frame(width: canvas * scale, height: canvas * scale, alignment: .topLeading)
        .offset(x: pose.shakeX * scale)
    }

    /// Covers the heads where the image draws them, then redraws the rail or post through them.
    @ViewBuilder
    private var hideDrawnHeads: some View {
        ForEach(Array(geometry.heads.enumerated()), id: \.offset) { _, head in
            let patch = head.insetBy(dx: -2, dy: -2)
            if let windowColor = geometry.windowColor {
                box(patch, windowColor, cornerRatio: 0)
                box(CGRect(x: patch.minX, y: geometry.rail.minY, width: patch.width, height: geometry.rail.height),
                    geometry.railColor, cornerRatio: 0)
            } else {
                // Open frame: nothing flat behind the carriage, so punch it out, then redraw the post.
                box(patch, Color.black, cornerRatio: 0).blendMode(.destinationOut)
                box(CGRect(x: geometry.rail.minX, y: patch.minY, width: geometry.rail.width, height: patch.height),
                    geometry.railColor, cornerRatio: 0)
            }
        }
    }

    @ViewBuilder
    private var part: some View {
        let height = geometry.partSize.height * pose.partHeight
        if height > 0.5 {
            box(CGRect(x: geometry.partCenterX - geometry.partSize.width / 2, y: geometry.floorY - height,
                       width: geometry.partSize.width, height: height),
                Color(hex: "#E8833A"), cornerRatio: 0.12)
                .scaleEffect(pose.partScale, anchor: .bottom)
        }
    }

    /// A rounded rectangle at `rect` in the asset's pixel space.
    private func box(_ rect: CGRect, _ color: Color, cornerRatio: CGFloat = 0.2) -> some View {
        RoundedRectangle(cornerRadius: min(rect.width, rect.height) * cornerRatio * scale, style: .continuous)
            .fill(color)
            .frame(width: rect.width * scale, height: rect.height * scale)
            .offset(x: rect.minX * scale, y: rect.minY * scale)
    }
}

#Preview("Every status") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 16) {
            ForEach(["PrinterH2C", "PrinterH2D", "PrinterP1S", "PrinterA1"], id: \.self) { asset in
                ForEach(PrinterState.allCases, id: \.self) { state in
                    VStack {
                        AnimatedPrinterImage(assetName: asset, state: state)
                            .frame(width: 80, height: 80)
                        Text(state.label).font(.caption2).foregroundStyle(.white)
                    }
                }
            }
        }
        .padding()
    }
    .background(Color.black)
}
