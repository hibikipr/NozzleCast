import SwiftUI
import WebKit

/// Full-screen live camera for a printer, playing Bambuddy's MJPEG stream in-app.
///
/// This replaces "Open Camera in Browser", which opened Bambuddy's `/camera/<id>` page in Safari.
/// That page only obtains a stream token when the browser is logged in to Bambuddy's web UI, so
/// opened from the app it loaded with no video. The stream endpoint itself only needs the stream
/// token the app already mints for snapshots, so the app plays it directly.
struct LiveCameraStreamView: View {
    var printerID: String
    var printerName: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var streamURL: URL?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let streamURL {
                MJPEGStreamWebView(url: streamURL)
                    .ignoresSafeArea()
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Couldn't start the live camera.", comment: "Live camera failed to load")
                        .ncFont(size: 14, relativeTo: .subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Text(printerName)
                    .ncFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                Spacer()
                GlassIconButton(systemName: "xmark") { dismiss() }
            }
            .padding(16)
        }
        .task {
            if let url = await store.liveStreamURL(printerID: printerID) {
                streamURL = url
            } else {
                failed = true
            }
        }
        .onDisappear {
            store.stopLiveStream(printerID: printerID)
        }
        .statusBarHidden()
    }
}

/// WebKit renders `multipart/x-mixed-replace` MJPEG natively in an `<img>`, which is exactly how
/// Bambuddy's own web UI shows it. A tiny page scales the stream to fit, letterboxed on black.
/// Dismissing the view tears the web view down, which closes the HTTP connection and so the
/// stream (Bambuddy stops an unwatched stream a few seconds later on its own).
private struct MJPEGStreamWebView: UIViewRepresentable {
    var url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.loadHTMLString(Self.page(for: url), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ()) {
        // Explicitly drop the stream connection rather than waiting for deallocation.
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private static func page(for url: URL) -> String {
        // The URL comes from our own URLComponents build, but escape it for the attribute anyway.
        let src = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=5">
        <style>
          html, body { margin: 0; height: 100%; background: #000; }
          body { display: flex; align-items: center; justify-content: center; }
          img { max-width: 100%; max-height: 100%; object-fit: contain; }
        </style>
        </head><body><img src="\(src)" alt=""></body></html>
        """
    }
}
