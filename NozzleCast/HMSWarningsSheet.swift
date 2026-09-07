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

            Text("\(printerName) · Warnings", comment: "Sheet title: printer name and its active HMS warnings")
                .ncFont(size: 17, weight: .bold, relativeTo: .headline)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(errors) { hms in
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
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(NCColor.statusWarning)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
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
            HMSError(fullCode: "0500050000000007", severity: 1, description: "The build plate is not detected."),
            HMSError(fullCode: "0701010003000001", severity: 2, description: nil),
        ]
    )
    .preferredColorScheme(.dark)
}
