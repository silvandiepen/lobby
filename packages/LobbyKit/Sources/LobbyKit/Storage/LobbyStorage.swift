// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Where LobbyKit's own files go.
public enum LobbyStorage {
    /// `Application Support/Lobby` on iOS, iPadOS and macOS, created when missing.
    ///
    /// tvOS gives an app no durable local storage, only Caches, which the system may empty while
    /// the app is not running. There the catalogue is fetched again and progress that had not
    /// reached the server yet can be lost.
    public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        #if os(tvOS)
        let root = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let root = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif
        let directory = try fileManager
            .url(for: root, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Lobby", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func catalogueFile(in directory: URL) -> URL {
        directory.appending(path: "catalogue.json", directoryHint: .notDirectory)
    }

    public static func categoriesFile(in directory: URL) -> URL {
        directory.appending(path: "categories.json", directoryHint: .notDirectory)
    }

    public static func popularFile(in directory: URL) -> URL {
        directory.appending(path: "popular.json", directoryHint: .notDirectory)
    }

    public static func progressFile(in directory: URL) -> URL {
        directory.appending(path: "progress.json", directoryHint: .notDirectory)
    }
}

/// A JSON file with a `version` field, written atomically.
enum VersionedFile {
    private struct Header: Decodable {
        var version: Int
    }

    enum Contents<Value> {
        /// No file yet.
        case missing
        case value(Value)
        /// Written by a newer build, or damaged. The caller decides what that costs.
        case unreadable
    }

    /// - Parameter migrate: Turns the bytes of an older version into the current shape. Add a
    ///   case there in the same change that raises `currentVersion`.
    static func read<Value: Decodable>(
        _ type: Value.Type, from url: URL, currentVersion: Int,
        migrate: (_ version: Int, _ data: Data) throws -> Value?
    ) -> Contents<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        do {
            let version = try JSONDecoder().decode(Header.self, from: data).version
            if version == currentVersion {
                return .value(try LobbyJSON.decoder().decode(Value.self, from: data))
            }
            if version < currentVersion, let migrated = try migrate(version, data) {
                return .value(migrated)
            }
            return .unreadable
        } catch {
            return .unreadable
        }
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LobbyJSON.encoder().encode(value).write(to: url, options: .atomic)
    }
}
