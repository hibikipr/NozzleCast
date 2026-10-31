import ActivityKit
import WidgetKit
import SwiftUI
import CoreGraphics
import ImageIO
import NozzleCastShared

/// The app's `NCColor.accent` (the barcode scanner's blue), which this target can't import.
private let accent = Color(hex: "#4F7FE0")
/// `NCColor.accentLight`: the build edge and accent-coloured text.
private let accentLight = Color(hex: "#8FB4FF")

/// Evaluates its content at init time; if construction throws the section renders as
/// EmptyView so every other section in the widget can still appear.
private struct SafeSection: View {
    private let _body: AnyView

    init<Content: View>(@ViewBuilder _ content: () throws -> Content) {
        _body = (try? AnyView(content())) ?? AnyView(EmptyView())
    }

    var body: some View { _body }
}

private func decodedImage(_ data: Data?) -> Image? {
    guard let data,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return Image(decorative: cgImage, scale: 1.0)
}

/// How much of the model has been printed: layers when the printer reports them (that's what
/// physically exists on the plate), the overall percentage otherwise.
private func buildFraction(_ state: PrintActivityAttributes.ContentState) -> Double {
    if let current = state.currentLayer, let total = state.totalLayers, total > 0 {
        return min(max(Double(current) / Double(total), 0), 1)
    }
    return min(max(state.progress, 0), 1)
}

/// The sliced-plate cover, drawn greyed out and refilled in colour from the bottom up to the
/// current layer — the print "building" in place. Deliberately the cover render only, never the
/// live camera snapshot: the fill reads as the model rising only on a render of the finished
/// model, and a camera frame already shows the partial print (so filling it would double-count).
///
/// The fill height only changes when a new content state arrives; ActivityKit animates that
/// change (up to ~2s) but never runs an animation between updates, so the edge glides on each
/// push and otherwise holds still.
private struct BuildUpThumbnail: View {
    var imageData: Data?
    var fraction: Double
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var showsEdge = true

    /// Bambu's cover renders crop close to the model but not flush; mapping the fill across the
    /// whole frame would make the first and last few layers look like nothing happened.
    private static let modelSpan: ClosedRange<Double> = 0.06...0.94

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let span = Self.modelSpan
        let filled = height * (span.lowerBound + (span.upperBound - span.lowerBound) * fraction)

        ZStack(alignment: .bottom) {
            shape.fill(Color(hex: "#16181C"))
            if let image = decodedImage(imageData) {
                // The relay downscales this to ~40px to fit ActivityKit's content-state budget
                // (see nozzlecast-relay's MAX_DIMENSION constants); `.high` resamples the upscale
                // smoothly rather than with `.medium`'s visible blockiness.
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .grayscale(1)
                    .opacity(0.28)
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: filled)
                    }
                if showsEdge, fraction > 0, fraction < 1 {
                    Capsule()
                        .fill(accentLight)
                        .frame(width: width - 12, height: 2)
                        .shadow(color: accent.opacity(0.8), radius: 4)
                        .offset(y: -filled + 1)
                }
            } else {
                Image(systemName: "printer.fill")
                    .font(.system(size: min(width, height) * 0.45))
                    .foregroundStyle(accent)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .animation(.smooth(duration: 1.1), value: fraction)
    }
}

/// A small colored count badge matching Bambuddy's own printer-card issue indicator — red for
/// `issueSeverity == "error"` (Bambuddy's Fatal/Serious), yellow/orange for `"warning"`
/// (Bambuddy's own Warning tier). `issueSeverity == nil` (including Bambuddy's Info tier, which
/// is deliberately excluded upstream — see `PrintActivityAttributes.ContentState.issueSeverity`)
/// renders nothing.
@ViewBuilder
private func issueBadge(_ state: PrintActivityAttributes.ContentState) -> some View {
    if let severity = state.issueSeverity, let count = state.issueCount, count > 0 {
        let color: Color = severity == "error" ? Color(hex: "#EF4444") : Color(hex: "#F97316")
        Text("\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(minWidth: 14, minHeight: 14)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
    }
}

private struct TelemetryChip: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

/// Nozzle and bed only — the layer count has its own rolling counter beside the countdown.
@ViewBuilder
private func temperatureChips(_ state: PrintActivityAttributes.ContentState) -> some View {
    HStack(spacing: 6) {
        if let left = state.nozzleTempC, let right = state.rightNozzleTempC {
            TelemetryChip(icon: "flame.fill", text: "L \(left)°")
            TelemetryChip(icon: "flame.fill", text: "R \(right)°")
        } else if let nozzle = state.nozzleTempC {
            TelemetryChip(icon: "flame.fill", text: "\(nozzle)°")
        }
        if let bed = state.bedTempC {
            TelemetryChip(icon: "square.stack", text: "\(bed)°")
        }
    }
}

/// The printer's actual last-reported progress — deliberately not locally interpolated from
/// elapsed time. A time-based estimate drifts from the real percentage whenever print speed
/// isn't perfectly linear (e.g. a slow first layer). Rolls to each new value on update.
private struct LiveProgressText: View {
    var state: PrintActivityAttributes.ContentState

    var body: some View {
        Text(state.progress, format: .percent.precision(.fractionLength(0)))
            .fontWeight(.bold)
            .monospacedDigit()
            .contentTransition(.numericText(value: state.progress))
            .animation(.smooth, value: state.progress)
    }
}

/// "82/128" beside a layers icon, the current layer rolling to each new value on update.
@ViewBuilder
private func layerCounter(_ state: PrintActivityAttributes.ContentState) -> some View {
    if let current = state.currentLayer, let total = state.totalLayers {
        HStack(spacing: 0) {
            Image(systemName: "square.3.layers.3d")
                .padding(.trailing, 3)
            Text("\(current)")
                .contentTransition(.numericText(value: Double(current)))
                .animation(.smooth, value: current)
            Text("/\(total)")
        }
        .monospacedDigit()
    }
}

/// The main app's bundle, two levels up from this extension's (`NozzleCast.app/PlugIns/…appex`).
/// The app localizes `stateLabel` with its own string catalog, which this target doesn't carry.
private let appBundle: Bundle = {
    let url = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: url) ?? .main
}()

/// States where the time remaining stops counting down. The relay and the notification extension
/// send these in English; the app sends "Paused" localized (`JobPhase.liveActivityLabel`).
private let stoppedStateLabels: Set<String> = [
    "Paused", "Complete", "Failed", "Cancelled", "Stopped", "Disconnected",
    String(localized: "Paused", bundle: appBundle, comment: "Live Activity status"),
]

/// The end date to count down to, or nil when a ticking countdown would lie — paused (the
/// printer's estimate stops moving but a timer wouldn't), finished, or no estimate at all.
private func countdownEnd(_ state: PrintActivityAttributes.ContentState) -> Date? {
    guard let end = state.estimatedEndAt,
          end > .now,
          end > state.startedAt,
          state.progress < 1,
          !stoppedStateLabels.contains(state.stateLabel)
    else { return nil }
    return end
}

/// Time remaining, ticking every second on-device between pushes — `Text(timerInterval:)` is one
/// of the few primitives a Live Activity keeps re-rendering without a new content state. Falls
/// back to the state label ("Paused", "Complete") whenever counting down would be wrong.
///
/// While the Lock Screen is dimmed (`isLuminanceReduced`) iOS stops per-second refreshes and draws
/// a seconds timer as "1:15:--", so there it counts in whole minutes instead ("1:15").
private struct Countdown: View {
    var state: PrintActivityAttributes.ContentState
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        if let end = countdownEnd(state) {
            Text(
                .currentDate,
                format: .timer(
                    countingDownIn: state.startedAt..<end,
                    maxPrecision: isLuminanceReduced ? .seconds(60) : .seconds(1)
                )
            )
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        } else {
            Text(state.stateLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

/// The job name, swapped for Bambuddy's stage detail ("Heating chamber") while there is one —
/// it pushes in from below on the update that sets it and back out on the one that clears it.
private struct JobSubtitle: View {
    var state: PrintActivityAttributes.ContentState
    var font: Font

    var body: some View {
        let isStage = state.stageDetail != nil
        if let text = state.stageDetail ?? state.jobName {
            Text(text)
                .font(font)
                .fontWeight(isStage ? .semibold : .regular)
                .foregroundStyle(isStage ? accentLight : .white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .id(text)
                .transition(.push(from: .bottom))
                .animation(.smooth, value: text)
        }
    }
}

/// Progress as 20 segments, each filling in on the update that crosses it. Still the printer's
/// own reported percentage — see `LiveProgressText`.
private struct SegmentedProgress: View {
    var progress: Double
    var height: CGFloat
    var spacing: CGFloat

    private static let segmentCount = 20

    var body: some View {
        let filled = Int((min(max(progress, 0), 1) * Double(Self.segmentCount)).rounded())
        HStack(spacing: spacing) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < filled ? accent : Color.white.opacity(0.13))
                    .frame(height: height)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: filled)
    }
}

/// Opens the printer's own detail screen rather than leaving people on the printer list — Apple's
/// Live Activity guidance: "Take people directly to related details and actions." One URL for the
/// whole activity (Lock Screen, compact, minimal, and expanded all tap through to it, since none
/// of the Dynamic Island regions below override it with their own `Link`), which also satisfies
/// "ensure both leading and trailing elements link to the same screen" — there's only one link.
private func deepLinkURL(for attributes: PrintActivityAttributes) -> URL {
    URL(string: "nozzlecast://printer/\(attributes.printerID)")!
}

struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(deepLinkURL(for: context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SafeSection {
                        BuildUpThumbnail(
                            imageData: context.state.coverImage,
                            fraction: buildFraction(context.state),
                            width: 52, height: 52, cornerRadius: 14
                        )
                        .overlay(alignment: .topTrailing) {
                            issueBadge(context.state).padding(-3)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    SafeSection {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.printerName)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            JobSubtitle(state: context.state, font: .caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SafeSection {
                        VStack(alignment: .trailing, spacing: 2) {
                            Countdown(state: context.state)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.trailing)
                                // A timer Text sizes itself to the widest value it could show;
                                // without a fixed width it wraps "1:09:35" onto two lines here.
                                .frame(width: 100, alignment: .trailing)
                            LiveProgressText(state: context.state)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SafeSection {
                        VStack(alignment: .leading, spacing: 8) {
                            SegmentedProgress(progress: context.state.progress, height: 8, spacing: 3)
                            HStack {
                                layerCounter(context.state)
                                Spacer()
                                if let end = context.state.estimatedEndAt {
                                    HStack(spacing: 3) {
                                        Image(systemName: "stopwatch")
                                        Text(end, style: .time)
                                    }
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        }
                        // Clear of the island's rounded bottom corners, which clipped the end time.
                        .padding(.horizontal, 8)
                    }
                }
            } compactLeading: {
                SafeSection {
                    BuildUpThumbnail(
                        imageData: context.state.coverImage,
                        fraction: buildFraction(context.state),
                        width: 22, height: 22, cornerRadius: 6, showsEdge: false
                    )
                }
            } compactTrailing: {
                SafeSection {
                    // Countdown while printing, the percentage otherwise (a paused or finished
                    // print has no remaining time worth showing in this little space).
                    if countdownEnd(context.state) != nil {
                        Countdown(state: context.state)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60, alignment: .trailing)
                    } else {
                        LiveProgressText(state: context.state)
                            .font(.caption2)
                            .foregroundStyle(.white)
                    }
                }
            } minimal: {
                SafeSection {
                    BuildUpThumbnail(
                        imageData: context.state.coverImage,
                        fraction: buildFraction(context.state),
                        width: 22, height: 22, cornerRadius: 6, showsEdge: false
                    )
                }
            }
        }
    }
}

private struct LockScreenView: View {
    var attributes: PrintActivityAttributes
    var state: PrintActivityAttributes.ContentState

    var body: some View {
        // Sized to stay inside the Lock Screen's 160pt cap with the padding included.
        HStack(alignment: .top, spacing: 14) {
            SafeSection {
                BuildUpThumbnail(
                    imageData: state.coverImage,
                    fraction: buildFraction(state),
                    width: 96, height: 128, cornerRadius: 16
                )
                .overlay(alignment: .topTrailing) {
                    issueBadge(state).padding(-3)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                SafeSection {
                    HStack {
                        Text(attributes.printerName)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        LiveProgressText(state: state)
                            .font(.caption)
                            .foregroundStyle(accentLight)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(accent.opacity(0.2)))
                    }
                }
                SafeSection {
                    JobSubtitle(state: state, font: .caption)
                }
                SafeSection {
                    Countdown(state: state)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
                SafeSection {
                    HStack {
                        if let end = state.estimatedEndAt {
                            HStack(spacing: 3) {
                                Image(systemName: "stopwatch")
                                // `.time` renders a localized clock time (respects the device's
                                // current timezone/locale automatically) rather than a countdown.
                                Text(end, style: .time)
                            }
                        }
                        Spacer()
                        layerCounter(state)
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                }
                SafeSection {
                    SegmentedProgress(progress: state.progress, height: 7, spacing: 2)
                }
                SafeSection {
                    temperatureChips(state)
                }
            }
        }
        .padding(14)
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

#Preview("Lock Screen", as: .content, using: PrintActivityAttributes(printerID: "mock-workshop-x1c", printerName: "Workshop X1C")) {
    PrintActivityWidget()
} contentStates: {
    PrintActivityAttributes.ContentState(
        progress: 0.64,
        stateLabel: "Printing",
        jobName: "Articulated_Dragon_v2.3.mf",
        startedAt: .now - 3600,
        estimatedEndAt: .now + 4320,
        currentLayer: 82,
        totalLayers: 128,
        nozzleTempC: 245,
        bedTempC: 60
    )
    PrintActivityAttributes.ContentState(
        progress: 0.66,
        stateLabel: "Printing",
        jobName: "Articulated_Dragon_v2.3.mf",
        startedAt: .now - 3600,
        estimatedEndAt: .now + 4100,
        currentLayer: 85,
        totalLayers: 128,
        nozzleTempC: 245,
        bedTempC: 60,
        stageDetail: "Heating chamber"
    )
    PrintActivityAttributes.ContentState(
        progress: 0.31,
        stateLabel: "Paused",
        jobName: "Vase_Mode_Twist.mf",
        startedAt: .now - 1800,
        estimatedEndAt: .now + 8700,
        nozzleTempC: 220,
        bedTempC: 55,
        issueSeverity: "warning",
        issueCount: 1
    )
}

#Preview("Dynamic Island – Expanded", as: .dynamicIsland(.expanded), using: PrintActivityAttributes(printerID: "mock-workshop-x1c", printerName: "Workshop X1C")) {
    PrintActivityWidget()
} contentStates: {
    PrintActivityAttributes.ContentState(
        progress: 0.64,
        stateLabel: "Printing",
        jobName: "Articulated_Dragon_v2.3.mf",
        startedAt: .now - 3600,
        estimatedEndAt: .now + 4320,
        currentLayer: 82,
        totalLayers: 128,
        nozzleTempC: 245,
        bedTempC: 60
    )
    PrintActivityAttributes.ContentState(
        progress: 0.48,
        stateLabel: "Printing",
        jobName: "Dual_Extrusion_Part.mf",
        startedAt: .now - 2700,
        estimatedEndAt: .now + 5400,
        currentLayer: 61,
        totalLayers: 128,
        nozzleTempC: 240,
        rightNozzleTempC: 220,
        bedTempC: 55
    )
}

#Preview("Dynamic Island – Compact", as: .dynamicIsland(.compact), using: PrintActivityAttributes(printerID: "mock-workshop-x1c", printerName: "Workshop X1C")) {
    PrintActivityWidget()
} contentStates: {
    PrintActivityAttributes.ContentState(
        progress: 0.64,
        stateLabel: "Printing",
        jobName: "Articulated_Dragon_v2.3.mf",
        startedAt: .now - 3600,
        estimatedEndAt: .now + 4320,
        nozzleTempC: 245,
        bedTempC: 60
    )
}
