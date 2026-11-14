import ActivityKit
import WidgetKit
import SwiftUI
import CoreGraphics
import ImageIO
import NozzleCastShared

/// The app's `NCColor.accent` (the barcode scanner's blue), which this target can't import.
let accent = Color(hex: "#4F7FE0")
/// `NCColor.accentLight`: the build edge and accent-coloured text.
let accentLight = Color(hex: "#8FB4FF")

/// Evaluates its content at init time; if construction throws the section renders as
/// EmptyView so every other section in the widget can still appear.
struct SafeSection: View {
    private let _body: AnyView

    init<Content: View>(@ViewBuilder _ content: () throws -> Content) {
        _body = (try? AnyView(content())) ?? AnyView(EmptyView())
    }

    var body: some View { _body }
}

/// The cover as the tile draws it: the image, its shape, and the backdrop it was flattened onto
/// (so the tile around it can match).
struct CoverArt {
    var image: Image
    /// Width over height.
    var aspectRatio: CGFloat
    var backdrop: Color
    var backdropIsLight: Bool
}

/// The sharp copy the app saved for this printer's job if there is one, else the small
/// `coverImage` from the content-state (a relay-started activity can be showing before the app
/// has woken to save it). Both are trimmed to the model and flattened onto one of
/// `CoverImageProcessing`'s two backdrops.
func coverArt(_ attributes: PrintActivityAttributes, _ state: PrintActivityAttributes.ContentState) -> CoverArt? {
    coverArt(printerID: attributes.printerID, jobName: state.jobName, fallback: state.coverImage)
}

/// The saved cover for a printer's job, or `fallback` (a content-state's small cover) when none is saved.
func coverArt(printerID: String, jobName: String?, fallback: Data? = nil) -> CoverArt? {
    let data = LiveActivityCoverStore.load(printerID: printerID, jobName: jobName) ?? fallback
    guard let data,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
          cgImage.width > 0, cgImage.height > 0
    else { return nil }
    let backdrop = CoverImageProcessing.backdrop(of: cgImage)
    return CoverArt(
        image: Image(decorative: cgImage, scale: 1.0),
        aspectRatio: CGFloat(cgImage.width) / CGFloat(cgImage.height),
        backdrop: Color(red: Double(backdrop.red) / 255, green: Double(backdrop.green) / 255, blue: Double(backdrop.blue) / 255),
        backdropIsLight: backdrop == CoverImageProcessing.backdropLight
    )
}

/// How much of the model has been printed: layers when the printer reports them (that's what
/// physically exists on the plate), the overall percentage otherwise.
func buildFraction(_ state: PrintActivityAttributes.ContentState) -> Double {
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
struct BuildUpThumbnail: View {
    var cover: CoverArt?
    var fraction: Double
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    /// The greyed-out model refilling in colour, with its edge. Off for the Dynamic Island's
    /// compact and minimal tiles: at ~22pt a mostly-grey model reads as an empty square, so those
    /// show the model in full colour.
    var showsBuildUp = true

    /// Room between the model and the tile's edge, as a share of the tile's shorter side: the
    /// cover is trimmed to the model, so without it the model would touch the rounded corners.
    private static let insetRatio: CGFloat = 0.08

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if let cover {
                shape.fill(cover.backdrop)
                model(cover)
            } else {
                shape.fill(Color(hex: "#16181C"))
                Image(systemName: "printer.fill")
                    .font(.system(size: min(width, height) * 0.45))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .animation(.smooth(duration: 1.1), value: fraction)
    }

    /// The cover fitted inside the tile (it's already trimmed, so cropping it would cut off the
    /// model): greyed out, with the colour refilled from the bottom up to the print height and a
    /// glowing edge on top. The fill follows the image, which is the model's own height.
    private func model(_ cover: CoverArt) -> some View {
        let inset = min(width, height) * Self.insetRatio
        let boxWidth = width - inset * 2, boxHeight = height - inset * 2
        let fitsWidth = cover.aspectRatio > boxWidth / boxHeight
        let modelWidth = fitsWidth ? boxWidth : boxHeight * cover.aspectRatio
        let modelHeight = fitsWidth ? boxWidth / cover.aspectRatio : boxHeight
        let filled = modelHeight * (showsBuildUp ? fraction : 1)

        return ZStack(alignment: .bottom) {
            cover.image
                .resizable()
                .interpolation(.high)
                .frame(width: modelWidth, height: modelHeight)
                .grayscale(1)
                .opacity(cover.backdropIsLight ? 0.4 : 0.32)
            cover.image
                .resizable()
                .interpolation(.high)
                .frame(width: modelWidth, height: modelHeight)
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: filled)
                }
            if showsBuildUp, fraction > 0, fraction < 1 {
                // The light accent disappears against the light backdrop, so the full one there.
                Capsule()
                    .fill(cover.backdropIsLight ? accent : accentLight)
                    .frame(width: modelWidth + 4, height: 2)
                    .shadow(color: accent.opacity(0.8), radius: 4)
                    .offset(y: -filled + 1)
            }
        }
        .frame(width: modelWidth, height: modelHeight)
    }
}

/// A small colored count badge matching Bambuddy's own printer-card issue indicator — red for
/// `issueSeverity == "error"` (Bambuddy's Fatal/Serious), yellow/orange for `"warning"`
/// (Bambuddy's own Warning tier). `issueSeverity == nil` (including Bambuddy's Info tier, which
/// is deliberately excluded upstream — see `PrintActivityAttributes.ContentState.issueSeverity`)
/// renders nothing.
@ViewBuilder
func issueBadge(_ state: PrintActivityAttributes.ContentState) -> some View {
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

struct TelemetryChip: View {
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
func temperatureChips(_ state: PrintActivityAttributes.ContentState) -> some View {
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
struct LiveProgressText: View {
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
func layerCounter(_ state: PrintActivityAttributes.ContentState) -> some View {
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
let appBundle: Bundle = {
    let url = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: url) ?? .main
}()

/// States where the time remaining stops counting down. The relay and the notification extension
/// send these in English; the app sends "Paused" localized (`JobPhase.liveActivityLabel`).
let stoppedStateLabels: Set<String> = [
    "Paused", "Complete", "Failed", "Cancelled", "Stopped", "Disconnected",
    String(localized: "Paused", bundle: appBundle, comment: "Live Activity status"),
]

/// The end date to count down to, or nil when a ticking countdown would lie — paused (the
/// printer's estimate stops moving but a timer wouldn't), finished, or no estimate at all.
func countdownEnd(_ state: PrintActivityAttributes.ContentState) -> Date? {
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
///
/// `compact` (the Dynamic Island's compact trailing slot) keeps the text short. iOS narrows that
/// slot when a second app's Live Activity is running, and an h:mm:ss timer clipped to "3:25:"
/// (issue #110): timer text doesn't honour `minimumScaleFactor`. So while an hour or more
/// remains it shows "3h 25m", which can shrink to fit but only changes on the next push (a print
/// pushes every percent or so), and in the last hour the ticking m:ss timer ("24:59"). A timer
/// can't tick as a short h:mm: with fewer fields or minute precision it spells the time out
/// ("1 hour, 11 minutes").
struct Countdown: View {
    var state: PrintActivityAttributes.ContentState
    var compact = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        if let end = countdownEnd(state), compact, end.timeIntervalSinceNow >= 3600 {
            Text(
                Duration.seconds(end.timeIntervalSinceNow)
                    .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            )
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        } else if let end = countdownEnd(state) {
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
struct JobSubtitle: View {
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
struct SegmentedProgress: View {
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

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0 == "#" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
