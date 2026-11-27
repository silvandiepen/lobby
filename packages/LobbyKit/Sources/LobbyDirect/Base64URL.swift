// SPDX-License-Identifier: MPL-2.0
import Foundation

extension Data {
    /// base64url without padding, in its one way of writing it. nil for anything else.
    public init?(base64URL text: String, count: Int? = nil) {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        guard let data = Data(base64Encoded: standard), data.base64URL == text, count == nil || data.count == count
        else { return nil }
        self = data
    }

    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
