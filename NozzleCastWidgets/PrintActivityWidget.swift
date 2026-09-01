import ActivityKit
import WidgetKit
import SwiftUI
import UIKit

private let accent = Color(red: 0x2A / 255, green: 0x5F / 255, blue: 0xCC / 255)

/// Renders the printer's live camera snapshot when Bambuddy has sent one, falling back to the
/// sliced-plate cover render fetched at print start, and only as a last resort (the brief window
/// before that fetch completes) a plain printer icon.
@ViewBuilder
private func thumbnailView(_ data: Data?, size: CGFloat) -> some View {
    if let data, let uiImage = UIImage(data: data) {
        Image(uiImage: uiImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    } else {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "printer.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(accent)
            }
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
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

@ViewBuilder
private func telemetryChips(_ state: PrintActivityAttributes.ContentState) -> some View {
    HStack(spacing: 6) {
        if let current = state.currentLayer, let total = state.totalLayers {
            TelemetryChip(icon: "square.3.layers.3d", text: "Layer \(current)/\(total)")
        }
        if let nozzle = state.nozzleTempC {
            TelemetryChip(icon: "flame.fill", text: "\(nozzle)°")
        }
        if let bed = state.bedTempC {
            TelemetryChip(icon: "square.stack", text: "\(bed)°")
        }
    }
}

/// A percentage that tracks the same date-interval interpolation as `progressView`'s bar,
/// rather than the raw `state.progress` snapshot — otherwise the two visibly disagree between
/// refreshes, since the bar keeps animating on-device while the number only updates when
/// `AppStore.refresh()` runs (there's no continuous polling).
private struct LiveProgressText: View {
    var state: PrintActivityAttributes.ContentState

    var body: some View {
        if let end = state.estimatedEndAt, end > state.startedAt {
            TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
                let total = end.timeIntervalSince(state.startedAt)
                let elapsed = context.date.timeIntervalSince(state.startedAt)
                let fraction = min(max(elapsed / total, 0), 1)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
            }
        } else {
            Text(state.progress, format: .percent.precision(.fractionLength(0)))
        }
    }
}

struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    thumbnailView(context.state.preferredThumbnail, size: 36)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveProgressText(state: context.state)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.printerName)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let job = context.state.jobName {
                            Text(job)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        progressView(state: context.state)
                        telemetryChips(context.state)
                    }
                }
            } compactLeading: {
                thumbnailView(context.state.preferredThumbnail, size: 20)
            } compactTrailing: {
                LiveProgressText(state: context.state)
                    .font(.caption2)
                    .foregroundStyle(.white)
            } minimal: {
                thumbnailView(context.state.preferredThumbnail, size: 16)
            }
        }
    }
}

@ViewBuilder
private func progressView(state: PrintActivityAttributes.ContentState) -> some View {
    if let end = state.estimatedEndAt, end > state.startedAt {
        ProgressView(timerInterval: state.startedAt...end, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .tint(accent)
    } else {
        ProgressView(value: state.progress)
            .tint(accent)
    }
}

private struct LockScreenView: View {
    var attributes: PrintActivityAttributes
    var state: PrintActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnailView(state.preferredThumbnail, size: 56)
                .overlay(alignment: .topLeading) {
                    if state.liveSnapshot != nil {
                        HStack(spacing: 3) {
                            Circle().fill(Color(hex: "#22C55E")).frame(width: 4, height: 4)
                            Text("LIVE").font(.system(size: 6, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(3)
                    }
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(attributes.printerName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Text(state.stateLabel)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let job = state.jobName {
                    Text(job)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                progressView(state: state)
                HStack {
                    LiveProgressText(state: state)
                    Spacer()
                    if let end = state.estimatedEndAt {
                        Text(end, style: .timer)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                telemetryChips(state)
            }
        }
        .padding()
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
