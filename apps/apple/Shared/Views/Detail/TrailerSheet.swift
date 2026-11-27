// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import WebKit

/// A trailer in YouTube's own embedded player, inside Lobby: captions, full screen and YouTube's
/// controls come with it. Nothing is downloaded or taken out of the player, and the sound stops
/// when Lobby goes to the background.
struct TrailerSheet: View {
    let key: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let page = Trailer.embedPage(key: key, origin: TrailerWebView.origin.absoluteString, language: Self.language) {
                    TrailerWebView(page: page) { url in openURL(url) }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("trailer.player")
                } else {
                    ContentUnavailableView("This trailer cannot be shown", systemImage: AppSymbol.trailer)
                }
            }
            .navigationTitle(title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("trailer.done")
                }
                if let url = Trailer.webURL(key: key) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("YouTube", systemImage: "arrow.up.right.square") { openURL(url) }
                            .help("Open at YouTube")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 460)
        #endif
        .environment(\.colorScheme, .dark)
        // No sound in the background: the sheet goes with the app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dismiss() }
        }
    }

    /// The household's language as this device has it, for the player's words and captions.
    private static var language: String? { Locale.current.language.languageCode?.identifier }
}

#if os(macOS)
private typealias WebViewRepresentable = NSViewRepresentable
#else
private typealias WebViewRepresentable = UIViewRepresentable
#endif

/// The web view that holds the embed. It goes nowhere else: a link out (YouTube's logo, a title
/// at the end) opens in the browser instead.
struct TrailerWebView: WebViewRepresentable {
    let page: String
    let leave: (URL) -> Void

    /// Where the page says it is: YouTube asks an app to name itself in the referrer.
    static let origin = URL(string: "https://mt.sil.lobby")!

    func makeCoordinator() -> Coordinator { Coordinator(leave: leave) }

    private func make(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if !os(macOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        #if !os(macOS)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        #endif
        view.loadHTMLString(page, baseURL: Self.origin)
        return view
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopEverything() }
    #else
    func makeUIView(context: Context) -> WKWebView { make(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopEverything() }
    #endif

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let leave: (URL) -> Void

        init(leave: @escaping (URL) -> Void) {
            self.leave = leave
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // The page itself, and whatever the player loads in its own frame.
            if action.targetFrame?.isMainFrame == false || action.request.url == TrailerWebView.origin
                || action.request.url?.scheme == "about"
            {
                return decisionHandler(.allow)
            }
            if action.navigationType == .other, action.request.url?.host() == TrailerWebView.origin.host() {
                return decisionHandler(.allow)
            }
            if let url = action.request.url, url.scheme == "https" { leave(url) }
            decisionHandler(.cancel)
        }

        /// A link that wants a window of its own.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url, url.scheme == "https" { leave(url) }
            return nil
        }
    }
}

private extension WKWebView {
    /// The sound stops with the sheet.
    func stopEverything() {
        pauseAllMediaPlayback(completionHandler: nil)
        stopLoading()
        loadHTMLString("", baseURL: nil)
    }
}
