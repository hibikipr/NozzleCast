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

    @Environment(AppStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .task(id: printerID) {
            image = nil
            while !Task.isCancelled {
                if let frame = await store.cameraSnapshot(printerID: printerID) {
                    image = frame
                }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }
}

/// The 60px-swatch / caption card used for AMS slots on Detail, the AMS sheet, and the post-scan slot picker.
struct AMSSlotCard: View {
    var spool: Spool?
    var slotIndex: Int
    var isActive: Bool = false

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
                } else {
                    StripePattern()
                    Text("Empty")
                        .ncFont(size: 10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(NCColor.textTertiary)
                }
            }
            .frame(width: 62, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(spool?.colorName ?? "Slot \(slotIndex + 1)")
                .ncFont(size: 9, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(NCColor.textSecondary)
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
                .strokeBorder(isActive ? NCColor.accent : Color.white.opacity(0.1), lineWidth: isActive ? 2 : 1)
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
