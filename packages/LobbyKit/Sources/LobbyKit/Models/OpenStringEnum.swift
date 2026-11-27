// SPDX-License-Identifier: MPL-2.0
/// A string enum from the API that a newer server may extend.
///
/// A value this build does not know decodes to `.unknown(raw)` and encodes back to the same
/// string, so a catalogue written by a newer server survives a round trip through the cache.
public protocol OpenStringEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    /// Every case this build knows, without `.unknown`.
    static var knownCases: [Self] { get }
    static func unknown(_ rawValue: String) -> Self
}

extension OpenStringEnum {
    /// Never fails: a string this build does not know becomes `.unknown`.
    public init(_ rawValue: String) {
        self = Self.knownCases.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    public init?(rawValue: String) {
        self.init(rawValue)
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// False for a value that came from a newer server.
    public var isKnown: Bool { Self.knownCases.contains(self) }
}
