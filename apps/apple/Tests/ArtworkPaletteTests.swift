// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import LobbyKit
import SwiftUI
import Testing

@testable import Lobby

@Suite struct ArtworkPaletteTests {
    private typealias RGB = (Double, Double, Double)

    /// A picture of vertical bands.
    private func picture(_ bands: [RGB]) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let width = 120 / CGFloat(bands.count)
        for (index, band) in bands.enumerated() {
            context.setFillColor(CGColor(srgbRed: band.0, green: band.1, blue: band.2, alpha: 1))
            context.fill(CGRect(x: CGFloat(index) * width, y: 0, width: width, height: 60))
        }
        return try #require(context.makeImage())
    }

    private func plain(_ color: Color) -> PlainColor {
        let resolved = color.resolve(in: EnvironmentValues())
        return PlainColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }

    private func contrast(_ a: PlainColor, _ b: PlainColor) -> Double {
        (max(a.luminance, b.luminance) + 0.05) / (min(a.luminance, b.luminance) + 0.05)
    }

    private let white = PlainColor(red: 1, green: 1, blue: 1)
    private let black = PlainColor(red: 0, green: 0, blue: 0)

    /// Everything the page can show: its colours and their mixtures.
    private func mixtures(_ colors: ArtworkColors) -> [PlainColor] {
        let all = [colors.base] + colors.glows
        let parts = [0, 0.25, 0.5, 0.75, 1]
        var result: [PlainColor] = []
        for a in parts { for b in parts { for c in parts {
            result.append(all[0].mixed(with: all[3], a).mixed(with: all[2], b).mixed(with: all[1], c))
        } } }
        return result
    }

    @Test(arguments: [(1.0, 1.0, 1.0), (0, 0, 0), (0.5, 0.5, 0.5), (0.02, 0.0, 0.03)])
    func aPictureWithoutColourHasNone(band: (Double, Double, Double)) throws {
        let palette = ArtworkPalette(of: try picture([band]))
        #expect(palette.leads.isEmpty)
        #expect(ArtworkColors(palette, style: .dark) == nil)
    }

    @Test func theLeadingColoursAreThePicturesOwn() throws {
        let palette = ArtworkPalette(of: try picture([(0.1, 0.5, 0.9), (0.1, 0.5, 0.9), (0.9, 0.4, 0.1), (0.5, 0.5, 0.5)]))
        #expect(palette.leads.count == 2)
        #expect(abs(palette.leads[0].hue - 0.58) < 0.03)
        #expect(abs(palette.leads[1].hue - 0.06) < 0.03)
    }

    /// Red lies on both sides of where the hues start.
    @Test func redIsOneColour() throws {
        let palette = ArtworkPalette(of: try picture([(0.9, 0.1, 0.13), (0.9, 0.13, 0.1)]))
        #expect(palette.leads.count == 1)
    }

    @Test func textIsReadableOnEveryPage() throws {
        // White, black and grey are above: the app's own colours. The rest of the extremes, and
        // every hue beside every other, as strong as a colour can be.
        var palettes = [
            ArtworkPalette(of: try picture([(1, 1, 0)])), ArtworkPalette(of: try picture([(1, 1, 0), (1, 1, 1), (0, 0, 0)])),
            ArtworkPalette(of: try picture([(0, 1, 0), (1, 1, 0.9)])), ArtworkPalette(of: try picture([(0, 0, 0.3)])),
        ]
        #expect(palettes.allSatisfy { !$0.leads.isEmpty })
        for first in stride(from: 0.0, to: 1, by: 1 / 12) { for second in stride(from: 0.0, to: 1, by: 1 / 12) {
            for saturation in [0.15, 1] {
                palettes.append(ArtworkPalette(leads: [first, second, first + 0.4].map {
                    .init(hue: $0.truncatingRemainder(dividingBy: 1), saturation: saturation)
                }))
            }
        } }
        var lowest: [ArtworkColors.Style: Double] = [:]
        func check(_ style: ArtworkColors.Style, _ text: PlainColor, _ back: PlainColor) {
            lowest[style] = min(lowest[style] ?? 99, contrast(text, back))
        }
        for palette in palettes {
            for (style, scheme) in [(ArtworkColors.Style.dark, ColorScheme.dark), (.light, .light)] {
                let colors = try #require(ArtworkColors(palette, style: style))
                for back in mixtures(colors) + [colors.sidebar, colors.panel] {
                    check(style, style == .dark ? white : black, back)
                    check(style, plain(.lobbySecondaryText(scheme)), back)
                    check(style, plain(.lobbyAccent(scheme)), back)
                }
            }
            for style in [ArtworkColors.Style.kids, .kidsDeep] {
                for back in mixtures(try #require(ArtworkColors(palette, style: style))) {
                    check(style, white, back)
                    // Season buttons: smaller words, on a chip.
                    #expect(contrast(white, back.mixed(with: black, 0.22)) >= 4.5)
                }
            }
        }
        for (style, contrast) in lowest {
            #expect(contrast >= (style == .kidsDeep ? 9 : style == .kids ? 7 : 4.5), "\(style): \(contrast)")
        }
        #expect(lowest.count == 4)
    }

    @Test func aDarkYellowIsGoldOrGreen() {
        for degrees in stride(from: 0.0, to: 360, by: 1) {
            let clean = ArtworkColors.cleanHue(degrees / 360) * 360
            #expect(clean <= 42.001 || clean >= 99.999)
            // Everything else stays what it is.
            if degrees <= 42 || degrees >= 100 { #expect(abs(clean - degrees) < 0.001) }
        }
        #expect(abs(ArtworkColors.cleanHue(50 / 360) * 360 - 40) < 0.001)
        // Leaves in the sun are a green.
        #expect(abs(ArtworkColors.cleanHue(65 / 360) * 360 - 112) < 0.001)
        #expect(abs(ArtworkColors.cleanHue(90 / 360) * 360 - 112) < 0.001)
    }

    @Test func aDarkOrangeIsAWineAndNotABrown() throws {
        for degrees in stride(from: 0.0, to: 54, by: 4) {
            let palette = ArtworkPalette(leads: [.init(hue: degrees / 360, saturation: 0.8)])
            let dark = try #require(ArtworkColors(palette, style: .dark))
            #expect(([dark.base, dark.top] + dark.glows).allSatisfy { $0.hsl.hue * 360 >= 335 && $0.hsl.saturation >= 0.25 })
            // The kids pages too: a bright orange wall is not what anybody asked for.
            let kids = try #require(ArtworkColors(palette, style: .kids))
            #expect(([kids.base, kids.top] + kids.glows).allSatisfy { $0.hsl.hue * 360 >= 335 && $0.hsl.saturation >= 0.4 })
        }
    }

    @Test func onADarkPageTheSeaCountsMoreThanTheLamp() throws {
        let palette = ArtworkPalette(leads: [
            .init(hue: 0.09, saturation: 0.7, weight: 1), .init(hue: 0.52, saturation: 0.6, weight: 0.4),
        ])
        #expect(abs(try #require(ArtworkColors(palette, style: .dark)).top.hsl.hue - 0.52) < 0.02)
        // With next to nothing cool in it, it stays a warm page.
        let lamp = ArtworkPalette(leads: [.init(hue: 0.09, saturation: 0.7, weight: 1), .init(hue: 0.52, saturation: 0.6, weight: 0.2)])
        #expect(try #require(ArtworkColors(lamp, style: .dark)).top.hsl.hue > 0.9)
    }

    @Test(arguments: [ArtworkColors.Style.dark, .kids, .kidsDeep])
    func noPageIsOliveOrGreyAnywhere(style: ArtworkColors.Style) throws {
        for first in stride(from: 0.0, to: 1, by: 1 / 24) { for second in stride(from: 0.0, to: 1, by: 1 / 24) {
            for third in [0.15, 0.4, 0.7, 0.95] { for saturation in [0.3, 1] {
                let palette = ArtworkPalette(leads: [first, second, third].map { .init(hue: $0, saturation: saturation) })
                let colors = try #require(ArtworkColors(palette, style: style))
                let least = ([colors.base] + colors.glows).map(\.chroma).min()!
                let all = mixtures(colors)
                #expect(all.allSatisfy { !$0.isOlive }, "\(first) \(second) \(third)")
                #expect(all.allSatisfy { $0.chroma >= 0.45 * least }, "\(first) \(second) \(third)")
            } }
        } }
    }

    @Test func kidsPagesAreRicherThanTheOthersAndDeeperWithMoreContrast() throws {
        for hue in stride(from: 0.0, to: 1, by: 1 / 36) {
            let palette = ArtworkPalette(leads: [.init(hue: hue, saturation: 0.7)])
            let kids = try #require(ArtworkColors(palette, style: .kids)), dark = try #require(ArtworkColors(palette, style: .dark))
            let deep = try #require(ArtworkColors(palette, style: .kidsDeep))
            #expect(kids.top.luminance > 1.8 * dark.top.luminance, "\(hue)")
            #expect(deep.top.luminance < kids.top.luminance)
            #expect(([kids.base, kids.top] + kids.glows).allSatisfy { $0.luminance <= ArtworkColors.kidsLimit })
        }
    }

    @Test func severalPicturesGiveTheStrongestOfEach() {
        let one = ArtworkPalette(leads: [.init(hue: 0.1, saturation: 0.5), .init(hue: 0.3, saturation: 0.5)])
        let other = ArtworkPalette(leads: [.init(hue: 0.6, saturation: 0.5)])
        #expect(ArtworkPalette(merging: [one, ArtworkPalette()]) == one)
        #expect(ArtworkPalette(merging: [one, other]).leads.map(\.hue) == [0.1, 0.6])
    }

    @Test func theColoursAreWorkedOutOnceAndKeptForOffline() async throws {
        let jpeg = try Make.jpeg(width: 40, height: 60)
        let stub = StubServer { _ in StubResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg) }
        let cache = try TemporaryDirectory(), kept = try TemporaryDirectory()
        let client = try stub.client()
        let artwork = Artwork(id: "art-1")
        let loader = ArtworkLoader(directory: cache.url, keptDirectory: kept.url, session: stub.session)
        let palette = try #require(await loader.palette(of: artwork, using: client))
        #expect(palette.leads.count == 1)
        // The colours are not one of the pictures a download left behind.
        await loader.keep([], using: nil)

        stub.setHandler { _ in throw URLError(.cannotConnectToHost) }
        try FileManager.default.removeItem(at: cache.url)
        let relaunched = ArtworkLoader(directory: cache.url, keptDirectory: kept.url, session: stub.session)
        #expect(await relaunched.palette(of: artwork, using: client, serverIsOutOfReach: true) == palette)
        #expect(await relaunched.palette(of: Artwork(id: "other"), using: client, serverIsOutOfReach: true) == nil)
        await relaunched.clear()
        #expect(await relaunched.palette(of: artwork, using: client, serverIsOutOfReach: true) == nil)
        #expect(stub.recorded.count == 1)
    }
}
