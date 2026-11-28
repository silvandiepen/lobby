// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest

/// The Lobby Servers that `Scripts/ui-test-server.sh` started on this Mac for the test run.
///
/// The simulator shares the Mac's network and file system, so the tests read the script's
/// `server.json` straight from the build folder and talk to the servers on 127.0.0.1.
struct TestServers: Decodable {
    struct Paired: Decodable {
        var url: URL
        var managerToken: String
    }

    struct Fresh: Decodable {
        var url: URL
        var setupSecret: String
    }

    /// Claimed, with the viewers "Alex", "Kids" and "Guest".
    var paired: Paired
    /// Not claimed yet.
    var fresh: Fresh
    /// Another household's server, claimed, with the viewer "Oma". nil from a
    /// script that started only two.
    var second: Paired?
    /// A film on this Mac for the upload test, sent as if it was picked in Files.
    var uploadFile: String?

    static func load(file: StaticString = #filePath) throws -> TestServers {
        let json = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/ui-test-server/server.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip(
                "The local Lobby Server is not running. The scheme starts it before testing; see apps/apple/Scripts/ui-test-server.sh and build/ui-test-server.log (it needs Node 24 and ffmpeg).")
        }
        return try JSONDecoder().decode(TestServers.self, from: data)
    }
}

/// The manager's side of the tests: what a parent would do on another device.
struct ManagerAPI {
    let server: TestServers.Paired

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: server.url.appending(path: "v1/\(path)"))
        request.httpMethod = method
        request.setValue("Bearer \(server.managerToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "ManagerAPI", code: status, userInfo: [
                NSLocalizedDescriptionKey: "\(method) \(path) answered \(status): \(String(decoding: data, as: UTF8.self))"
            ])
        }
        return data
    }

    /// Types the code a new device shows.
    func approve(code: String, role: String = "viewer") async throws {
        // "manager" and "viewer" are the roles of older apps; a household admin is an access.
        let grant = role == "householdAdmin" ? ["access": role] : ["role": role]
        _ = try await request("POST", "pairing/approve", body: ["code": code].merging(grant) { $1 })
    }

    /// Removes every paired device that is not the manager itself.
    func removeOtherDevices() async throws {
        struct List: Decodable {
            struct Device: Decodable {
                var id: String
                var revokedAt: Double?
            }
            var devices: [Device]
            var currentDeviceId: String
        }
        let list = try JSONDecoder().decode(List.self, from: try await request("GET", "devices"))
        for device in list.devices where device.id != list.currentDeviceId && device.revokedAt == nil {
            _ = try await request("DELETE", "devices/\(device.id)")
        }
    }

    private struct Viewer: Decodable {
        struct Kids: Decodable {
            var allowedGroupIds: [String]
        }
        var id: String
        var name: String
        var avatar: String?
        var kids: Kids?
    }

    private func viewers() async throws -> [Viewer] {
        struct List: Decodable { var profiles: [Viewer] }
        return try JSONDecoder().decode(List.self, from: try await request("GET", "profiles")).profiles
    }

    private func viewerID(_ name: String) async throws -> String {
        guard let viewer = try await viewers().first(where: { $0.name == name }) else {
            throw NSError(domain: "ManagerAPI", code: 404, userInfo: [NSLocalizedDescriptionKey: "No viewer \(name)."])
        }
        return viewer.id
    }

    /// Adds a viewer, instead of one a broken-off test left.
    func addViewer(_ name: String) async throws {
        try await removeViewer(name)
        _ = try await request("POST", "profiles", body: ["name": name, "color": "pink"])
    }

    func removeViewer(_ name: String) async throws {
        for viewer in try await viewers() where viewer.name == name {
            _ = try await request("DELETE", "profiles/\(viewer.id)")
        }
    }

    /// Makes a viewer a kids viewer, or (nil) an ordinary one.
    ///
    /// - Returns: false when the server does not know kids viewers.
    func setKids(_ kids: [String: [String]]?, ofViewer name: String) async throws -> Bool {
        let id = try await viewerID(name)
        guard let listed = try JSONSerialization.jsonObject(with: try await request("GET", "profiles")) as? [String: Any],
            let all = listed["profiles"] as? [[String: Any]], all.allSatisfy({ $0.keys.contains("kids") })
        else { return false }
        var sent = kids
        if sent != nil {
            for key in ["allowedGroupIds", "allowedCategoryIds", "allowedItemIds", "blockedItemIds"] where sent?[key] == nil {
                sent?[key] = []
            }
        }
        _ = try await request("PATCH", "profiles/\(id)", body: ["kids": sent.map { $0 as Any } ?? NSNull()])
        return true
    }

    func avatar(ofViewer name: String) async throws -> String? {
        try await viewers().first { $0.name == name }?.avatar
    }

    func kidsGroups(ofViewer name: String) async throws -> [String] {
        try await viewers().first { $0.name == name }?.kids?.allowedGroupIds ?? []
    }

    func groupIDs() async throws -> [String] {
        struct List: Decodable {
            struct Group: Decodable { var id: String }
            var groups: [Group]
        }
        return try JSONDecoder().decode(List.self, from: try await request("GET", "categories")).groups.map(\.id)
    }

    func itemID(titled title: String) async throws -> String {
        struct Page: Decodable {
            struct Item: Decodable {
                var id: String
                var title: String
            }
            var items: [Item]
        }
        let page = try JSONDecoder().decode(Page.self, from: try await request("GET", "library"))
        guard let item = page.items.first(where: { $0.title == title }) else {
            throw NSError(domain: "ManagerAPI", code: 404, userInfo: [NSLocalizedDescriptionKey: "No title \(title)."])
        }
        return item.id
    }

    /// Binds every paired device that is not the manager itself.
    func bindOtherDevices(toViewer name: String) async throws {
        struct List: Decodable {
            struct Device: Decodable {
                var id: String
                var revokedAt: Double?
            }
            var devices: [Device]
            var currentDeviceId: String
        }
        let viewer = try await viewerID(name)
        let list = try JSONDecoder().decode(List.self, from: try await request("GET", "devices"))
        for device in list.devices where device.id != list.currentDeviceId && device.revokedAt == nil {
            _ = try await request("PATCH", "devices/\(device.id)", body: ["kidsProfileId": viewer])
        }
    }

    /// Puts films on every paired device that is not the manager itself.
    func send(_ titles: [String]) async throws {
        struct List: Decodable {
            struct Device: Decodable {
                var id: String
                var revokedAt: Double?
            }
            var devices: [Device]
            var currentDeviceId: String
        }
        let list = try JSONDecoder().decode(List.self, from: try await request("GET", "devices"))
        for device in list.devices where device.id != list.currentDeviceId && device.revokedAt == nil {
            for title in titles {
                _ = try await request("POST", "devices/\(device.id)/wanted", body: ["kind": "item", "itemId": try await itemID(titled: title)])
            }
        }
    }
}
