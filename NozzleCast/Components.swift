import SwiftUI

/// Wraps its children left-to-right, starting a new row when the next child would overflow
/// the available width. Used for the AMS dot row so printers with many trays wrap instead of
/// scrolling off-screen.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var rowSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows = rowsFitting(width: width, subviews: subviews)
        if rows.isEmpty { rows = [[]] }
        let height = rows.reduce(0) { partial, row in
            partial + (row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
        } + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width.isFinite ? width : (rows.first?.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing } ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func rowsFitting(width: CGFloat, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        var rows: [[LayoutSubviews.Element]] = []
        var current: [LayoutSubviews.Element] = []
        var x: CGFloat = 0
        for subview in subviews {
            let w = subview.sizeThatFits(.unspecified).width
            if x + w > width, !current.isEmpty {
                rows.append(current)
                current = []
                x = 0
            }
            current.append(subview)
            x += w + spacing
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

/// Polls a printer's chamber camera snapshot endpoint and shows the latest frame, falling back
/// to a dim camera glyph when live mode is off or no frame has loaded yet.
struct LiveCameraView: View {
    var printerID: String
    var pollInterval: Double = 3
    /// Shows the underlying failure reason under the placeholder icon instead of just the
    /// icon alone — only worth doing where there's room to read it (the detail view header),
    /// not the small Monitor-list thumbnail. Only used when there's no cover fallback to show
    /// instead (see below).
    var showsErrorDetail: Bool = false
    /// When set, falls back to the printer's plate render instead of a plain camera glyph once
    /// there's no live frame to show — a camera integration being down (as this was built for,
    /// on a P1S) shouldn't leave the thumbnail solid black when a render is already available.
    var coverFallbackJobIdentity: String?
    /// Reflects whether an actual live frame is currently on screen (as opposed to the cover
    /// fallback or the plain icon) — callers use this to gate a "LIVE" badge, which shouldn't
    /// show over a static plate render.
    @Binding var isShowingLiveFrame: Bool

    @Environment(AppStore.self) private var store
    @State private var image: UIImage?

    private var error: String? { store.cameraErrors[printerID] }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let jobIdentity = coverFallbackJobIdentity {
                PrinterCoverImage(printerID: printerID, jobIdentity: jobIdentity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.white.opacity(0.3))
                    if showsErrorDetail, let error {
                        Text(error)
                            .ncFont(size: 11, relativeTo: .caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
        }
        .task(id: printerID) {
            image = nil
            isShowingLiveFrame = false
            while !Task.isCancelled {
                if let frame = await store.cameraSnapshot(printerID: printerID) {
                    image = frame
                    isShowingLiveFrame = true
                } else {
                    isShowingLiveFrame = image != nil
                }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }
}

/// The rendered plate preview for a printer's current or most recently finished job — refetched
/// whenever the job identity changes (a new job means a new render; the same job's render never
/// changes, so there's no need to poll). Falls back to a package glyph when nothing's loaded yet,
/// the fetch fails, or the printer has no completed job to show a render for.
struct PrinterCoverImage: View {
    var printerID: String
    /// Identifies the current job so the view knows when to refetch — pass something that
    /// changes when the job does, e.g. the job filename (or printer id alone if idle).
    var jobIdentity: String

    @Environment(AppStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(NCColor.textTertiary)
            }
        }
        .task(id: "\(printerID)-\(jobIdentity)") {
            image = await store.printerCoverImage(printerID: printerID)
        }
    }
}

/// Full-screen, pinch-to-zoom presentation of a printer's plate render, opened by tapping the
/// thumbnail in the job card.
struct CoverImageViewer: View {
    var printerID: String
    var jobIdentity: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, min(5, lastScale * value))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale == 1 {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.25)) {
                            scale = 1
                            lastScale = 1
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            GlassIconButton(systemName: "xmark") { dismiss() }
                .padding(16)
                .padding(.top, 8)
        }
        .task(id: "\(printerID)-\(jobIdentity)") {
            image = await store.printerCoverImage(printerID: printerID)
        }
    }
}

/// The 60px-swatch / caption card used for AMS slots on Detail, the AMS sheet, and the post-scan slot picker.
struct AMSSlotCard: View {
    var spool: Spool?
    var slotIndex: Int
    var isActive: Bool = false
    /// The tray's raw hardware-reported state — when it says a spool is loaded but `spool`
    /// is nil, the printer read a color/type off the RFID (or it was set manually) that
    /// hasn't been matched to anything in inventory yet, distinct from a genuinely empty bay.
    var tray: AMSTray? = nil

    private var needsAssignment: Bool { spool == nil && (tray?.needsAssignment ?? false) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let spool {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: spool.colorHex))
                    Text(spool.material.rawValue)
                        .ncFont(size: 10, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(Color(hex: spool.colorHex).isLight ? .black : .white)
                        .padding(.horizontal, 4)
                } else if needsAssignment {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tray?.rawColorHex.map { Color(hex: $0) } ?? NCColor.well)
                    VStack(spacing: 2) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        if let material = tray?.rawMaterialLabel {
                            Text(material)
                                .ncFont(size: 9, weight: .bold, relativeTo: .caption2)
                        }
                    }
                    .foregroundStyle((tray?.rawColorHex.map { Color(hex: $0).isLight } ?? false) ? .black : .white)
                } else {
                    StripePattern()
                    Text("Empty")
                        .ncFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(NCColor.textTertiary)
                }
            }
            .frame(width: 62, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(
                spool?.colorName
                    ?? (needsAssignment
                        ? String(localized: "Unassigned", comment: "AMS slot: printer reports a spool loaded but it isn't matched to inventory")
                        : String(localized: "Slot \(slotIndex + 1)", comment: "Fallback label for an empty AMS slot"))
            )
            .ncFont(size: 9, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(needsAssignment ? NCColor.statusWarning : NCColor.textSecondary)
            .lineLimit(1)
            .frame(width: 62)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NCColor.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isActive ? NCColor.accent : (needsAssignment ? NCColor.statusWarning : Color.white.opacity(0.1)),
                    lineWidth: isActive || needsAssignment ? 2 : 1
                )
        )
    }
}

/// 45°-stripe fill for empty AMS slot wells.
struct StripePattern: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "#2a2a2a")))
            let stripeWidth: CGFloat = 8
            let stripeColor = Color(hex: "#1c1c1c")
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + stripeWidth, y: 0))
                path.addLine(to: CGPoint(x: x + stripeWidth, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(stripeColor))
                x += stripeWidth * 2
            }
        }
    }
}

struct StatusDot: View {
    var state: PrinterState
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .modifier(PulseEffect(active: state.pulses))
    }
}

struct PulseEffect: ViewModifier {
    var active: Bool
    @State private var animate = false

    func body(content: Content) -> some View {
        content
            .overlay(
                Circle()
                    .stroke(NCColor.statusPrinting, lineWidth: 2)
                    .scaleEffect(animate ? 2.2 : 1)
                    .opacity(active ? (animate ? 0 : 0.6) : 0)
            )
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(NCColor.statusPrinting)
                .frame(width: 5, height: 5)
                .modifier(PulseEffect(active: true))
            Text("LIVE")
                .ncFont(size: 7, weight: .bold, relativeTo: .caption2)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Small rounded status badge — wifi strength, firmware version, warning count, etc.
struct InfoPill: View {
    var icon: String
    var text: String
    var tint: Color = NCColor.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .ncFont(size: 11.5, weight: .medium, relativeTo: .caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// One fan's icon + speed percentage, used in the printer detail fan-speed row.
struct FanSpeedChip: View {
    var icon: String
    var caption: String
    var percent: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(NCColor.accentLight)
            Text(Double(percent ?? 0) / 100, format: .percent.precision(.fractionLength(0)))
                .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(percent == nil ? NCColor.textTertiary : NCColor.textPrimary)
            Text(caption)
                .ncFont(size: 11.5, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NCColor.wellAlt))
    }
}

/// One physical bay in a dual-nozzle printer's automatic nozzle-changer rack.
struct NozzleRackChip: View {
    var slot: NozzleRackSlot

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(slot.filamentColorHex.map { Color(hex: $0) } ?? NCColor.well)
                if slot.isEmpty {
                    Text("—")
                        .ncFont(size: 12, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(NCColor.textTertiary)
                } else {
                    Text(slot.diameter)
                        .ncFont(size: 11, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(
                            (slot.filamentColorHex.map { Color(hex: $0).isLight } ?? false) ? .black.opacity(0.7) : .white
                        )
                }
            }
            .frame(width: 40, height: 40)
        }
    }
}

struct FilterChip: View {
    var title: String
    var isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(isActive ? .white : NCColor.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isActive ? NCColor.accent : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }
}

struct GlassIconButton: View {
    var systemName: String
    var size: CGFloat = 36
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.black.opacity(0.45)))
                .background(Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
        }
        .buttonStyle(.plain)
    }
}

struct ControlButton: View {
    var systemName: String
    var label: String
    var isActive: Bool = false
    var isDestructiveHint: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isActive ? NCColor.accentLight : .white)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle().fill(isActive ? NCColor.accent.opacity(0.22) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Circle().strokeBorder(isActive ? NCColor.accent : Color.white.opacity(0.1), lineWidth: 1)
                    )
                Text(label)
                    .ncFont(size: 11, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(NCColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Printer product photo when a known asset exists, otherwise a generic glyph.
struct PrinterThumbnailImage: View {
    var assetName: String?

    var body: some View {
        if let assetName {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "printer.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(NCColor.textTertiary)
                .padding(6)
        }
    }
}

struct ProgressBar: View {
    var progress: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(NCColor.accent)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: height)
    }
}
