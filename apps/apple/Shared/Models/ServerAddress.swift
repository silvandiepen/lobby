// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What a person types on the Connect screen, turned into the address `LobbyClient` wants.
enum ServerAddress {
    /// The port Lobby Server listens on unless its config says otherwise.
    static let defaultPort = 8674

    /// - `media.example.ts.net` becomes `http://media.example.ts.net:8674`
    /// - `192.168.1.20:9000` becomes `http://192.168.1.20:9000`
    /// - an address with a scheme is taken as written, without a path, query or `/v1`
    ///
    /// nil when there is no host in it.
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let hasScheme = trimmed.range(of: "://") != nil
        guard var components = URLComponents(string: hasScheme ? trimmed : "http://" + trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        if !hasScheme, components.port == nil {
            components.port = defaultPort
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// The address as the Settings screen shows it: without the scheme for plain HTTP.
    static func display(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else {
            return url.absoluteString
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return components.scheme == "https" ? "https://\(host)\(port)" : "\(host)\(port)"
    }
}
