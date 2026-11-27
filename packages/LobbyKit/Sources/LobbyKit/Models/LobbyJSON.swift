// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The JSON conventions of `docs/api.md`: instants are integer milliseconds since the Unix epoch.
/// Every model in this package is decoded and encoded through these, for the wire and for the
/// local stores, so a `Date` is always a UTC instant with millisecond precision.
public enum LobbyJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let milliseconds = try decoder.singleValueContainer().decode(Double.self)
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.millisecondsSince1970)
        }
        // The API never omits a field. Sorted keys keep the stored files stable to diff.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension Date {
    /// The instant as the API writes it.
    public var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    public init(millisecondsSince1970 milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
