// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A trailer that can play now: YouTube's, in YouTube's own player, or a file of the household's.
enum Trailer: Hashable, Sendable, Identifiable {
    case youtube(key: String)
    /// A trailer file beside the film, which plays in Lobby's own player.
    case file(PlayRequest, title: String)

    var id: String {
        switch self {
        case .youtube(let key): "youtube-\(key)"
        case .file(let request, _): request.id
        }
    }

    var title: String {
        switch self {
        case .youtube: "Trailer"
        case .file(_, let title): title
        }
    }

    /// What YouTube calls a video: letters, digits, `-` and `_`. Anything else is not put in a URL.
    static func isKey(_ key: String) -> Bool {
        (6...20).contains(key.count) && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The page with YouTube's embedded player (`youtube-nocookie.com`), for a web view whose page
    /// is at `origin`. YouTube asks embedding apps to say who they are with the referrer; nothing
    /// is downloaded or taken out of the player.
    static func embedPage(key: String, origin: String, language: String?) -> String? {
        guard isKey(key) else { return nil }
        var parts = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(key)")
        var query = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "origin", value: origin),
        ]
        if let language, language.allSatisfy({ $0.isLetter }), language.count <= 3 {
            query.append(URLQueryItem(name: "hl", value: language))
            query.append(URLQueryItem(name: "cc_lang_pref", value: language))
        }
        parts?.queryItems = query
        guard let src = parts?.url?.absoluteString else { return nil }
        return """
            <!doctype html>
            <html><head>
            <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
            <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}\
            iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style>
            </head><body>
            <iframe src="\(src)" title="Trailer" allow="autoplay; encrypted-media; fullscreen; picture-in-picture" \
            allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
            </body></html>
            """
    }

    /// The YouTube app's own address for a video, on the Apple TV.
    static func appURL(key: String) -> URL? {
        guard isKey(key) else { return nil }
        return URL(string: "youtube://www.youtube.com/watch?v=\(key)")
    }

    /// YouTube's page for a video, for whoever wants to go there.
    static func webURL(key: String) -> URL? {
        guard isKey(key) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }
}
