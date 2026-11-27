// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Testing

@testable import Lobby

/// The palette's contrast, by WCAG's formula.
@Suite struct ThemeTests {
    private func luminance(_ color: Color, over background: Color = .black) -> Double {
        let environment = EnvironmentValues()
        let top = color.resolve(in: environment), below = background.resolve(in: environment)
        func channel(_ a: Float, _ b: Float) -> Double {
            // Colours lie over each other in the encoded values, as on screen.
            let value = Double(a) * Double(top.opacity) + Double(b) * (1 - Double(top.opacity))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(top.red, below.red) + 0.7152 * channel(top.green, below.green)
            + 0.0722 * channel(top.blue, below.blue)
    }

    private func contrast(_ front: Double, _ back: Double) -> Double {
        (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func textIsReadableOnEverySurface(scheme: ColorScheme) {
        let text: Color = scheme == .dark ? .white : .black
        let surfaces: [Color] = [.lobbyBackground(scheme), .lobbySidebar(scheme), .lobbySurface(scheme), .lobbySurfaceRaised(scheme)]
        for surface in surfaces {
            let back = luminance(surface)
            #expect(contrast(luminance(text), back) >= 7)
            #expect(contrast(luminance(.lobbySecondaryText(scheme)), back) >= 4.5)
        }
        // Links and buttons of words: on the window, the sidebar and a panel.
        for surface in surfaces.prefix(3) {
            #expect(contrast(luminance(.lobbyAccent(scheme)), luminance(surface)) >= 4.5)
        }
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func theChosenRowIsReadable(scheme: ColorScheme) {
        let text: Color = scheme == .dark ? .white : .black
        for surface in [Color.lobbySidebar(scheme), .lobbySurface(scheme)] {
            let fill = luminance(.lobbySelection(scheme), over: surface)
            #expect(contrast(luminance(text), fill) >= 7)
            // A symbol needs 3.
            #expect(contrast(luminance(.lobbyAccent(scheme)), fill) >= 3)
        }
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func theSurfacesAreSolidAndDiffer(scheme: ColorScheme) {
        let surfaces: [Color] = [.lobbyBackground(scheme), .lobbySidebar(scheme), .lobbySurface(scheme), .lobbySurfaceRaised(scheme)]
        #expect(Set(surfaces).count == surfaces.count)
        #expect(surfaces.allSatisfy { $0.resolve(in: EnvironmentValues()).opacity == 1 })
    }

    @Test func theAssetAccentIsTheThemesAccent() {
        for scheme in [ColorScheme.dark, .light] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let asset = Color("AccentColor").resolve(in: environment), theme = Color.lobbyAccent(scheme).resolve(in: environment)
            #expect(abs(asset.red - theme.red) < 0.01)
            #expect(abs(asset.green - theme.green) < 0.01)
            #expect(abs(asset.blue - theme.blue) < 0.01)
        }
    }
}
