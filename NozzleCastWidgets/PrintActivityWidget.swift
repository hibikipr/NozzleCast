import ActivityKit
import WidgetKit
import SwiftUI
import CoreGraphics
import ImageIO
import NozzleCastShared

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
                            cover: coverArt(context.attributes, context.state),
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
                        cover: coverArt(context.attributes, context.state),
                        fraction: buildFraction(context.state),
                        width: 22, height: 22, cornerRadius: 6, showsBuildUp: false
                    )
                }
            } compactTrailing: {
                SafeSection {
                    // Countdown while printing, the percentage otherwise (a paused or finished
                    // print has no remaining time worth showing in this little space).
                    if countdownEnd(context.state) != nil {
                        // Sized for the short text `compact` keeps to ("3h 25m", "24:59"). The
                        // old 60 pt frame was wider than the slot iOS leaves beside another
                        // app's Live Activity.
                        Countdown(state: context.state, compact: true)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 42, alignment: .trailing)
                    } else {
                        LiveProgressText(state: context.state)
                            .font(.caption2)
                            .foregroundStyle(.white)
                    }
                }
            } minimal: {
                SafeSection {
                    BuildUpThumbnail(
                        cover: coverArt(context.attributes, context.state),
                        fraction: buildFraction(context.state),
                        width: 22, height: 22, cornerRadius: 6, showsBuildUp: false
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
                    cover: coverArt(attributes, state),
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
