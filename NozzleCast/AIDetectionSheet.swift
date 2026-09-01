import SwiftUI

/// Mirrors Bambuddy's own "AI Failure Detection" popover — status plus the last error from the
/// Obico integration (a self-hosted spaghetti-detection ML service; account-wide, not a native
/// printer feature, so there's no per-printer error to show, only the global last one).
struct AIDetectionSheet: View {
    var printerName: String
    var isMonitoring: Bool
    var lastError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                Text("\(printerName) · AI Failure Detection", comment: "Sheet title: printer name and the AI failure detection feature")
                    .ncFont(size: 17, weight: .bold, relativeTo: .headline)

                HStack {
                    Text("Status")
                        .ncFont(size: 14, relativeTo: .subheadline)
                        .foregroundStyle(NCColor.textSecondary)
                    Spacer()
                    Text(isMonitoring ? String(localized: "Monitoring", comment: "AI failure detection status") : String(localized: "Idle", comment: "AI failure detection status"))
                        .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(isMonitoring ? NCColor.statusPrinting : .white)
                }

                Text(
                    isMonitoring
                        ? "This print is being watched for failures."
                        : "No print is being monitored right now. Monitoring starts automatically with the next print.",
                    comment: "AI failure detection explanation, shown for the active and idle states respectively"
                )
                .ncFont(size: 13, relativeTo: .footnote)
                .foregroundStyle(NCColor.textTertiary)

                if let lastError, !lastError.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(NCColor.statusError)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last error")
                                .ncFont(size: 12.5, weight: .semibold, relativeTo: .footnote)
                                .foregroundStyle(NCColor.statusError)
                            Text(lastError)
                                .ncFont(size: 12.5, relativeTo: .footnote)
                                .foregroundStyle(NCColor.textSecondary)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NCColor.statusError.opacity(0.12)))
                }
            }
            .padding(20)
        }
        .background(Color(hex: "#212121").ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.hidden)
    }
}
