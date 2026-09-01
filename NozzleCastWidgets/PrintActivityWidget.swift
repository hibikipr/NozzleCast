import ActivityKit
import WidgetKit
import SwiftUI

private let accent = Color(red: 0x2A / 255, green: 0x5F / 255, blue: 0xCC / 255)

struct PrintActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "printer.fill")
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.printerName)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let job = context.state.jobName {
                            Text(job)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        progressView(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "printer.fill")
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2)
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "printer.fill")
                    .foregroundStyle(accent)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "printer.fill")
                    .foregroundStyle(accent)
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
                Text(state.progress, format: .percent.precision(.fractionLength(0)))
                Spacer()
                if let end = state.estimatedEndAt {
                    Text(end, style: .timer)
                }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding()
    }
}
