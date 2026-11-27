// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The server this device is paired with. Not a secret: the token is in the `CredentialStore`,
/// keyed by `serverID`.
public struct SavedConnection: Codable, Hashable, Sendable {
    /// The address in use: the one that last worked.
    public var serverAddress: URL
    public var serverID: String
    public var serverName: String
    public var deviceID: String
    /// What the server said about where it can be reached. nil until it said so.
    public var addresses: ServerAddresses?
    /// The address the device was paired through: typed, or found on the network.
    public var pairedAddress: URL?

    public init(
        serverAddress: URL, serverID: String, serverName: String, deviceID: String, addresses: ServerAddresses? = nil,
        pairedAddress: URL? = nil
    ) {
        self.serverAddress = serverAddress
        self.serverID = serverID
        self.serverName = serverName
        self.deviceID = deviceID
        self.addresses = addresses
        self.pairedAddress = pairedAddress
    }

    /// Every address worth trying, in order: the server's own list, home first, then the one
    /// the device was paired through and the one in use, in case the list does not have them.
    public var candidates: [URL] {
        var seen: Set<URL> = []
        return ((addresses?.inOrder ?? []) + [pairedAddress, serverAddress].compactMap { $0 })
            .filter { seen.insert($0).inserted }
    }
}

/// The remembered server and viewer, in `UserDefaults`.
public struct ConnectionPreferences: Sendable {
    private static let connectionKey = "lobby.connection"
    private static let activeProfileKey = "lobby.activeProfileID"

    private let suiteName: String?

    /// - Parameter suiteName: An app group's suite, or nil for the app's standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public var connection: SavedConnection? {
        get {
            guard let data = defaults.data(forKey: Self.connectionKey) else { return nil }
            return try? JSONDecoder().decode(SavedConnection.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.connectionKey)
            } else {
                defaults.removeObject(forKey: Self.connectionKey)
            }
        }
    }

    /// The viewer last chosen on this device.
    public var activeProfileID: String? {
        get { defaults.string(forKey: Self.activeProfileKey) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.activeProfileKey)
            } else {
                defaults.removeObject(forKey: Self.activeProfileKey)
            }
        }
    }
}
