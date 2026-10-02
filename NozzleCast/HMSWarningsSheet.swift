import SwiftUI

struct HMSWarningsSheet: View {
    var printerName: String
    var errors: [HMSError]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            Text("\(printerName) · Alerts", comment: "Sheet title: printer name and its active HMS alerts")
                .ncFont(size: 17, weight: .bold, relativeTo: .headline)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 0) {
                    // Most severe first: what stopped the print, then what paused it, then notices.
                    ForEach(errors.sorted { $0.level < $1.level }) { hms in
                        HMSWarningRow(hms: hms) { openURL($0) }
                        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 20)
                    }
                }
            }
        }
        .background(Color(hex: "#212121").ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.hidden)
    }
}

/// How each Bambu alert level looks — shared by the alert rows and the printer's alert pill so
/// the two never disagree. Levels come from `HMSError.level` (Bambuddy v1.2.5.7+, #2728).
extension HMSError.Level {
    var color: Color {
        switch self {
        case .error: NCColor.statusError
        case .warning: NCColor.statusWarning
        case .notification: NCColor.accentLight
        case .unknown: NCColor.textTertiary
        }
    }

    var symbol: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .notification: "info.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var caption: String {
        switch self {
        case .error: String(localized: "Error · stopped the print", comment: "HMS alert level 1")
        case .warning: String(localized: "Warning · paused the print", comment: "HMS alert level 2")
        case .notification: String(localized: "Notification", comment: "HMS alert level 3: informational, no effect on the print")
        case .unknown: String(localized: "Unknown level", comment: "HMS alert with no recognised level")
        }
    }
}

private struct HMSWarningRow: View {
    var hms: HMSError
    var onOpenURL: (URL) -> Void

    @State private var wikiDescription: String?
    @State private var isLoading = true

    private var displayText: String {
        if let description = hms.description, !description.isEmpty { return description }
        return wikiDescription ?? hms.displayCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hms.level.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(hms.level.color)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hms.level.caption)
                        .ncFont(size: 11, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(hms.level.color)
                    Text(displayText)
                        .ncFont(size: 14, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                    Text(hms.displayCode)
                        .ncFont(size: 11, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                }
                Spacer()
                if isLoading, hms.description?.isEmpty != false {
                    ProgressView().scaleEffect(0.7)
                }
            }

            if let code = hms.dashedCode, let url = HMSCodeLookup.wikiURL(forCode: code) {
                Button {
                    onOpenURL(url)
                } label: {
                    Text("View on Bambu Wiki")
                        .ncFont(size: 12.5, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(NCColor.accentLight)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .task {
            guard hms.description?.isEmpty != false, let code = hms.dashedCode else {
                isLoading = false
                return
            }
            wikiDescription = await HMSCodeLookup.description(forCode: code)
            isLoading = false
        }
    }
}

#Preview {
    HMSWarningsSheet(
        printerName: "Workshop X1C",
        errors: [
            HMSError(fullCode: "0501040000030002", severity: 3, description: "Threaded rods need lubrication now."),
            HMSError(fullCode: "0500050000010007", severity: 1, description: "The build plate is not detected."),
            HMSError(fullCode: "0500060000020005", severity: 2, description: nil),
        ]
    )
    .preferredColorScheme(.dark)
}
