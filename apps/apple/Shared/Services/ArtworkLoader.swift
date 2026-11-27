// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import ImageIO
import LobbyKit

/// Posters, backdrops and stills from `GET /v1/artwork/{id}`, kept on the device.
///
/// An artwork id never changes its picture (`docs/api.md`), so a file fetched once is never
/// fetched again. The files are in Caches: the system may remove them, and they come back.
///
/// The pictures of what was downloaded are kept apart, where the system leaves them alone:
/// without the server they are all there is.
actor ArtworkLoader {
    /// One size for a kept picture: enough for a poster on any screen, a still and a logo.
    static let keptWidth = ArtworkWidth.w800
    /// And one for a picture that fills a window.
    #if os(macOS)
    static let keptBannerWidth = ArtworkWidth.w1920
    #else
    static let keptBannerWidth = ArtworkWidth.w1280
    #endif

    private let directory: URL
    private let keptDirectory: URL?
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void
    private var palettes: ArtworkPalettes
    private var memory: [String: CGImage] = [:]
    private var memoryOrder: [String] = []
    private var running: [String: Task<CGImage, any Error>] = [:]

    /// How many decoded pictures stay in memory. A screen of posters is about forty.
    private let memoryLimit = 160

    /// - Parameters:
    ///   - directory: The cache.
    ///   - keptDirectory: Where the pictures of downloads stay, e.g. beside the downloads.
    ///   - sleep: The wait before asking a busy server again.
    init(
        directory: URL, keptDirectory: URL? = nil, session: URLSession = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sleep = sleep
        self.directory = directory
        self.keptDirectory = keptDirectory
        self.session = session
        // Beside the pictures that stay.
        palettes = ArtworkPalettes(directory: keptDirectory ?? directory)
    }

    /// - Parameters:
    ///   - pixelWidth: How wide the picture is drawn, in pixels (points × display scale).
    ///   - serverIsOutOfReach: Do not ask the server: use what is on the device, or fail.
    func image(
        for artwork: Artwork, pixelWidth: Int, using client: LobbyClient, serverIsOutOfReach: Bool = false
    ) async throws -> CGImage {
        let width = ArtworkWidth.covering(pixels: pixelWidth)
        let key = "\(artwork.id)-\(width.rawValue)"
        if let cached = memory[key] { return cached }
        if let running = running[key] { return try await running.value }

        let file = directory.appending(path: Self.fileName(for: key), directoryHint: .notDirectory)
        // Kept as a banner, or (from an earlier version of the app, or of a poster) in the one size.
        let kept = [keptFile(for: artwork, isBanner: true), keptFile(for: artwork, isBanner: false)].compactMap { $0 }
        let request = client.authorizedRequest(for: client.artworkURL(artwork, width: width))
        let session = session
        let sleep = sleep
        // Not on the actor: what is in memory does not wait behind what is being decoded.
        let task = Task.detached(priority: .userInitiated) { () throws -> CGImage in
            if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
                return image
            }
            // The kept picture of a download, in its one size, when the server is not asked
            // or does not answer.
            func keptImage() -> CGImage? {
                kept.lazy.compactMap { try? Data(contentsOf: $0) }.compactMap(Self.decode).first
            }
            if serverIsOutOfReach {
                guard let image = keptImage() else { throw LobbyError.unreachable(.notConnectedToInternet) }
                return image
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.data(for: request, session: session, sleep: sleep)
            } catch {
                guard let image = keptImage() else { throw error }
                return image
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let image = Self.decode(data) else {
                throw LobbyError.invalidResponse("No picture for artwork \(artwork.id).")
            }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return image
        }
        running[key] = task
        defer { running[key] = nil }

        let image = try await task.value
        // A kept picture that stood in for a larger one is not remembered as that one: the
        // right size is fetched when the server is back.
        if !serverIsOutOfReach {
            remember(image, for: key)
        }
        return image
    }

    /// A picture's leading colours. nil when there is no way to the picture now; asked again
    /// the next time.
    func palette(of artwork: Artwork, using client: LobbyClient, serverIsOutOfReach: Bool = false) async -> ArtworkPalette? {
        if let known = palettes.palette(of: artwork.id) { return known }
        guard let image = try? await image(
            for: artwork, pixelWidth: ArtworkWidth.w200.rawValue, using: client, serverIsOutOfReach: serverIsOutOfReach)
        else { return nil }
        let palette = ArtworkPalette(of: image)
        palettes.keep(palette, of: artwork.id)
        return palette
    }

    /// A category's logo. Kept with the pictures that stay, so the Library looks the same
    /// without the server; a logo never changes, so it is fetched once.
    func logo(_ logo: CategoryLogo, using client: LobbyClient, serverIsOutOfReach: Bool = false) async throws -> CGImage {
        let key = "logo-\(logo.id)"
        if let cached = memory[key] { return cached }
        let file = (keptDirectory ?? directory)
            .appending(path: Self.logoPrefix + Self.fileName(for: logo.id), directoryHint: .notDirectory)
        if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            remember(image, for: key)
            return image
        }
        guard !serverIsOutOfReach else { throw LobbyError.unreachable(.notConnectedToInternet) }
        let (data, response) = try await Self.data(
            for: client.authorizedRequest(for: client.logoURL(logo)), session: session, sleep: sleep)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let image = Self.decode(data) else {
            throw LobbyError.invalidResponse("No picture for logo \(logo.id).")
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        remember(image, for: key)
        return image
    }

    /// The answer, once the server gets to it: a wall of posters can be more than it makes at once.
    private static func data(
        for request: URLRequest, session: URLSession, sleep: @Sendable (Duration) async throws -> Void
    ) async throws -> (Data, URLResponse) {
        try await LobbyError.waitingItsTurn(sleep: sleep) {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                throw LobbyError.rateLimited(
                    message: "Lobby Server is busy.",
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            }
            return (data, response)
        }
    }

    private static let logoPrefix = "logo-"

    /// Makes the kept pictures those of `wanted`, the artwork of what is downloaded: fetches
    /// the ones that are missing and removes the rest. A picture that cannot be fetched now
    /// is tried again the next time this is called.
    ///
    /// - Parameters:
    ///   - banners: The ids of the ones that fill a window, and are kept larger.
    ///   - client: nil when the server is out of reach: nothing is fetched then.
    func keep(_ wanted: [Artwork], banners: Set<String> = [], using client: LobbyClient?) async {
        guard let keptDirectory else { return }
        func name(_ artwork: Artwork) -> String { Self.keptName(for: artwork.id, isBanner: banners.contains(artwork.id)) }
        let names = Dictionary(wanted.map { (name($0), $0) }, uniquingKeysWith: { first, _ in first })
        // The logos and the colours live in the same folder and are not a download's pictures.
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: keptDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(Self.logoPrefix) && $0 != ArtworkPalettes.fileName }
        // A banner kept small by an earlier version of the app stays until the large one is here.
        let smaller = Set(wanted.filter { banners.contains($0.id) && !present.contains(name($0)) }.map {
            Self.keptName(for: $0.id, isBanner: false)
        })
        for name in present.subtracting(names.keys).subtracting(smaller) {
            try? FileManager.default.removeItem(at: keptDirectory.appending(path: name, directoryHint: .notDirectory))
        }
        guard let client else { return }
        for (name, artwork) in names where !present.contains(name) {
            let request = client.authorizedRequest(for: client.artworkURL(artwork, width: banners.contains(artwork.id) ? Self.keptBannerWidth : Self.keptWidth))
            guard let (data, response) = try? await Self.data(for: request, session: session, sleep: sleep),
                (response as? HTTPURLResponse)?.statusCode == 200, Self.decode(data) != nil
            else { continue }
            try? FileManager.default.createDirectory(at: keptDirectory, withIntermediateDirectories: true)
            try? data.write(to: keptDirectory.appending(path: name, directoryHint: .notDirectory), options: .atomic)
            let small = Self.keptName(for: artwork.id, isBanner: false)
            if smaller.contains(small) {
                try? FileManager.default.removeItem(at: keptDirectory.appending(path: small, directoryHint: .notDirectory))
            }
        }
    }

    private static func keptName(for id: String, isBanner: Bool) -> String {
        isBanner ? "wide-" + fileName(for: id) : fileName(for: id)
    }

    private func keptFile(for artwork: Artwork, isBanner: Bool) -> URL? {
        keptDirectory?.appending(path: Self.keptName(for: artwork.id, isBanner: isBanner), directoryHint: .notDirectory)
    }

    /// Removes every stored picture, for signing out.
    func clear() {
        memory = [:]
        memoryOrder = []
        palettes.forget()
        try? FileManager.default.removeItem(at: directory)
        if let keptDirectory {
            try? FileManager.default.removeItem(at: keptDirectory)
        }
    }

    private func remember(_ image: CGImage, for key: String) {
        memory[key] = image
        memoryOrder.append(key)
        while memoryOrder.count > memoryLimit {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    /// An artwork id is opaque, so it is not trusted as a file name.
    private static func fileName(for key: String) -> String {
        String(StableHash.value(of: key), radix: 16) + ".jpg"
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
