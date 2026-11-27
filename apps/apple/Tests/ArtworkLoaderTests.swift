// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import ImageIO
import LobbyKit
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Lobby

@Suite struct ArtworkLoaderTests {
    private static func jpeg(width: Int, height: Int) throws -> Data {
        try Make.jpeg(width: width, height: height)
    }

    @Test func aPosterIsFetchedOnceWithTheCredentialAndKept() async throws {
        let picture = try Self.jpeg(width: 40, height: 60)
        let stub = StubServer { _ in StubResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: picture) }
        let directory = try TemporaryDirectory()
        let client = try stub.client(token: "device-token")
        let artwork = Artwork(id: "art-1", width: 2000, height: 3000)

        let loader = ArtworkLoader(directory: directory.url, session: stub.session)
        let image = try await loader.image(for: artwork, pixelWidth: 366, using: client)
        #expect(image.width == 40)
        _ = try await loader.image(for: artwork, pixelWidth: 366, using: client)

        #expect(stub.recorded.count == 1)
        #expect(stub.recorded[0].path == "/v1/artwork/art-1")
        // 366 pixels wide is covered by the 400 the server scales to.
        #expect(stub.recorded[0].query["w"] == "400")
        #expect(stub.recorded[0].headers["Authorization"] == "Bearer device-token")

        // After a relaunch the picture comes from the file, with the server out of reach.
        stub.setHandler { _ in throw URLError(.cannotConnectToHost) }
        let relaunched = ArtworkLoader(directory: directory.url, session: stub.session)
        #expect(try await relaunched.image(for: artwork, pixelWidth: 366, using: client).height == 60)
    }

    @Test func aBusyServerIsAskedAgainWhenItSaidSo() async throws {
        let picture = try Self.jpeg(width: 40, height: 60)
        let asked = Mutex(0)
        let waited = Mutex<[Duration]>([])
        let stub = StubServer { _ in
            let count = asked.withLock { $0 += 1; return $0 }
            return count < 3
                ? StubResponse(status: 429, headers: ["Retry-After": "7"])
                : StubResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: picture)
        }
        let loader = ArtworkLoader(
            directory: try TemporaryDirectory().url, session: stub.session, sleep: { duration in waited.withLock { $0.append(duration) } })
        let image = try await loader.image(for: Artwork(id: "art-1"), pixelWidth: 200, using: try stub.client())
        #expect(image.width == 40)
        #expect(waited.withLock { $0 } == [.seconds(7), .seconds(7)])
    }

    @Test func aServerWithoutThePictureIsAnErrorNotAnEmptyImage() async throws {
        let stub = StubServer { _ in .error(404, "not_found", "No such artwork.") }
        let loader = ArtworkLoader(directory: try TemporaryDirectory().url, session: stub.session)
        await #expect(throws: LobbyError.self) {
            try await loader.image(for: Artwork(id: "gone"), pixelWidth: 200, using: try stub.client())
        }
    }
}
