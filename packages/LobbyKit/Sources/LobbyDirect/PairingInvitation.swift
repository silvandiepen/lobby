// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What a new device outside needs to pair: where the introducer is, and the code of the window a
/// manager opened. As a QR code and link: `lobby://pair?i=<introducer>&c=<code>`. A household's
/// invitation also says whose household and whose server it is: `&h=<household>&s=<server>`.
public struct PairingInvitation: Hashable, Sendable {
    public let introducer: IntroducerAddress
    /// Sixteen characters.
    public let code: String
    /// The household an invitation is for, to show; nil for a window of one's own household.
    public let household: String?
    /// The name of the server it leads to, to show.
    public let server: String?

    public init?(introducer: String, code: String, household: String? = nil, server: String? = nil) {
        guard let address = IntroducerAddress(introducer), let code = PairingCode.read(code) else { return nil }
        self.introducer = address
        self.code = code
        self.household = Self.shown(household)
        self.server = Self.shown(server)
    }

    /// A name to show, as far as it can be shown: no control characters, not too long.
    private static func shown(_ name: String?) -> String? {
        guard let name else { return nil }
        let plain = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : String(plain.prefix(60))
    }

    public init?(link: String) {
        guard link.utf8.count <= 600, let parts = URLComponents(string: link), parts.scheme?.lowercased() == "lobby",
            parts.host == "pair"
        else { return nil }
        func value(_ name: String) -> String? {
            let found = (parts.queryItems ?? []).filter { $0.name == name }
            return found.count == 1 ? found[0].value : nil
        }
        guard let introducer = value("i"), let code = value("c") else { return nil }
        self.init(introducer: introducer, code: code, household: value("h"), server: value("s"))
    }

    public var link: String {
        var parts = URLComponents()
        parts.scheme = "lobby"
        parts.host = "pair"
        parts.queryItems =
            [URLQueryItem(name: "i", value: introducer.url.absoluteString), URLQueryItem(name: "c", value: code)]
            + (household.map { [URLQueryItem(name: "h", value: $0)] } ?? [])
            + (server.map { [URLQueryItem(name: "s", value: $0)] } ?? [])
        return parts.string ?? ""
    }
}

/// The code of a pairing window: 16 characters of Crockford's base32.
public enum PairingCode {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 16

    /// What was typed so far, as the code reads it: capitals, no spaces or hyphens, O as 0, I and
    /// L as 1. Anything else is left out.
    public static func clean(_ typed: String) -> String {
        String(
            typed.uppercased().map { $0 == "O" ? "0" : $0 == "I" || $0 == "L" ? "1" : $0 }
                .filter(alphabet.contains).prefix(length))
    }

    /// A whole code. nil when it cannot be one.
    public static func read(_ typed: String) -> String? {
        let allowed = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard typed.count <= 64, allowed.count == length else { return nil }
        let code = clean(allowed)
        return code.count == length ? code : nil
    }

    /// `XXXX-XXXX-XXXX-XXXX`, as far as it goes.
    public static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { at in
            String(code.dropFirst(at).prefix(4))
        }.joined(separator: "-")
    }
}

/// `lobby://join?c=<code>&i=<introducer>`: an invitation into another household's server.
/// The household's server side decides what the code is; here it is the code of a
/// pairing window, and the link opens pairing from outside with it filled in. The introducer may
/// be left out: then the person types it, or the one known from before is used.
public struct HouseholdInvitation: Hashable, Sendable {
    /// What was in the link, cleaned as a typed code would be.
    public let code: String
    public let introducer: IntroducerAddress?

    public init?(link: String) {
        guard link.utf8.count <= 600, let parts = URLComponents(string: link), parts.scheme?.lowercased() == "lobby",
            parts.host?.lowercased() == "join"
        else { return nil }
        func value(_ names: String...) -> String? {
            let found = (parts.queryItems ?? []).filter { names.contains($0.name) }
            return found.count == 1 ? found[0].value : nil
        }
        guard let typed = value("c", "code") else { return nil }
        let code = PairingCode.clean(typed)
        guard !code.isEmpty else { return nil }
        self.code = code
        introducer = value("i", "introducer").flatMap { IntroducerAddress($0) }
    }

    /// The pairing invitation it stands for, when it says everything that takes.
    public var pairing: PairingInvitation? {
        introducer.flatMap { PairingInvitation(introducer: $0.url.absoluteString, code: code) }
    }

    /// Whether a link is one of the app's pairing links: `lobby://pair…` or `lobby://join…`.
    public static func isPairingLink(_ link: String) -> Bool {
        PairingInvitation(link: link) != nil || HouseholdInvitation(link: link) != nil
    }
}
