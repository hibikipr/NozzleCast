import ActivityKit
import WidgetKit
import SwiftUI
import CoreGraphics
import ImageIO
import NozzleCastShared

private let accent = Color(red: 0x2A / 255, green: 0x5F / 255, blue: 0xCC / 255)

/// Evaluates its content at init time; if construction throws the section renders as
/// EmptyView so every other section in the widget can still appear.
private struct SafeSection: View {
    private let _body: AnyView

    init<Content: View>(@ViewBuilder _ content: () throws -> Content) {
        _body = (try? AnyView(content())) ?? AnyView(EmptyView())
    }

    var body: some View { _body }
}

/// Renders the printer's live camera snapshot when Bambuddy has sent one, falling back to the
/// sliced-plate cover render fetched at print start, and only as a last resort (the brief window
/// before that fetch completes) a plain printer icon.
@ViewBuilder
private func thumbnailView(_ data: Data?, size: CGFloat) -> some View {
    if let data,
       let source = CGImageSourceCreateWithData(data as CFData, nil),
       let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        Image(decorative: cgImage, scale: 1.0)
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

/// The printer's actual last-reported progress — deliberately not locally interpolated from
/// elapsed time. A time-based estimate drifts from the real percentage whenever print speed
/// isn't perfectly linear (e.g. a slow first layer), and a Live Activity's rendering only
/// guarantees continuous on-device refresh for a few specific primitives (date-styled `Text`,
/// `ProgressView(timerInterval:)`) — an arbitrary `TimelineView` like the one this used to use
/// isn't reliably re-evaluated between pushes in a Live Activity, so it wasn't even buying the
/// smoothness it was written for.
private struct LiveProgressText: View {
    var state: PrintActivityAttributes.ContentState

    var body: some View {
        // The single most important number on the card — Apple's Live Activity guidance calls
        // for "large, heavier-weight text" for key information, so this always carries at least
        // a bold weight regardless of the size a call site layers on top.
        Text(state.progress, format: .percent.precision(.fractionLength(0)))
            .fontWeight(.bold)
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
                    SafeSection {
                        thumbnailView(context.state.preferredThumbnail, size: 36)
                            .overlay(alignment: .topTrailing) {
                                issueBadge(context.state).padding(-3)
                            }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SafeSection {
                        LiveProgressText(state: context.state)
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    SafeSection {
                        Text(context.attributes.printerName)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SafeSection {
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
                }
            } compactLeading: {
                SafeSection {
                    thumbnailView(context.state.preferredThumbnail, size: 20)
                }
            } compactTrailing: {
                SafeSection {
                    LiveProgressText(state: context.state)
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
            } minimal: {
                SafeSection {
                    thumbnailView(context.state.preferredThumbnail, size: 16)
                }
            }
        }
    }
}

@ViewBuilder
private func progressView(state: PrintActivityAttributes.ContentState) -> some View {
    // The actual reported percentage, not a time-interpolated estimate — see LiveProgressText.
    ProgressView(value: state.progress)
        .tint(accent)
}

private struct LockScreenView: View {
    var attributes: PrintActivityAttributes
    var state: PrintActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SafeSection {
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
                    .overlay(alignment: .topTrailing) {
                        issueBadge(state).padding(-3)
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                SafeSection {
                    HStack {
                        Text(attributes.printerName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(state.stateLabel)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                SafeSection {
                    if let job = state.jobName {
                        Text(job)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                SafeSection {
                    progressView(state: state)
                }
                SafeSection {
                    HStack {
                        LiveProgressText(state: state)
                        Spacer()
                        if let end = state.estimatedEndAt {
                            HStack(spacing: 3) {
                                Image(systemName: "stopwatch")
                                // `.time` renders a localized clock time (respects the device's
                                // current timezone/locale automatically) rather than a countdown.
                                Text(end, style: .time)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                }
                SafeSection {
                    telemetryChips(state)
                }
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
