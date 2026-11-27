// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation

/// The leading colours of a picture: up to three hues, the strongest first. Empty for a picture
/// without colour (grey, black and white).
struct ArtworkPalette: Codable, Hashable, Sendable {
    struct Lead: Codable, Hashable, Sendable {
        /// 0…1.
        var hue: Double
        /// 0…1, HSL.
        var saturation: Double
        /// How much of the picture it is, beside the strongest. nil: not known.
        var weight: Double? = nil
    }

    static let limit = 3

    var leads: [Lead] = []

    init(leads: [Lead] = []) {
        self.leads = leads
    }

    /// The colours of several pictures together: the strongest of each.
    init(merging palettes: [ArtworkPalette]) {
        let coloured = palettes.filter { !$0.leads.isEmpty }
        // One picture keeps all of its colours.
        leads = coloured.count == 1 ? coloured[0].leads : Array(coloured.compactMap(\.leads.first).prefix(Self.limit))
    }

    init(of image: CGImage) {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let isDrawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard isDrawn else { return }

        // How much of the picture each hue has, the vivid and the middle tones counting most.
        let binCount = 36
        var weights = [Double](repeating: 0, count: binCount), saturations = weights
        var coloured = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let color = PlainColor(
                red: Double(pixels[index]) / 255, green: Double(pixels[index + 1]) / 255, blue: Double(pixels[index + 2]) / 255)
            let (hue, saturation, lightness) = color.hsl
            // A nearly black pixel can have a high saturation and no colour to see.
            guard saturation >= 0.15, color.chroma >= 0.08 else { continue }
            coloured += 1
            let weight = saturation * (0.2 + 2 * min(lightness, 1 - lightness))
            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            weights[bin] += weight
            saturations[bin] += weight * saturation
        }
        guard coloured * 25 >= side * side else { return }

        func around(_ bin: Int, _ values: [Double]) -> Double {
            values[bin] + 0.5 * (values[(bin + 1) % binCount] + values[(bin + binCount - 1) % binCount])
        }
        let ranked = (0..<binCount).sorted { around($0, weights) > around($1, weights) }
        let strongest = around(ranked[0], weights)
        var chosen: [Int] = []
        for bin in ranked where weights[bin] > 0 && around(bin, weights) >= 0.08 * strongest {
            let isApart = chosen.allSatisfy { other in
                let distance = abs(bin - other)
                return min(distance, binCount - distance) >= 3
            }
            if isApart { chosen.append(bin) }
            if chosen.count == Self.limit { break }
        }
        leads = chosen.map { bin in
            Lead(hue: (Double(bin) + 0.5) / Double(binCount), saturation: around(bin, saturations) / around(bin, weights), weight: around(bin, weights) / strongest)
        }
    }
}

/// A colour as numbers, to work with. sRGB, 0…1.
struct PlainColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = saturation * min(lightness, 1 - lightness)
        func channel(_ offset: Double) -> Double {
            let k = (offset + hue * 12).truncatingRemainder(dividingBy: 12)
            return lightness - chroma * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(red: channel(0), green: channel(8), blue: channel(4))
    }

    var chroma: Double { max(red, green, blue) - min(red, green, blue) }

    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let top = max(red, green, blue), lightness = (top + min(red, green, blue)) / 2
        guard chroma > 0 else { return (0, 0, lightness) }
        let sector =
            if top == red { (green - blue) / chroma + (green < blue ? 6 : 0) }
            else if top == green { (blue - red) / chroma + 2 }
            else { (red - green) / chroma + 4 }
        return (sector / 6, chroma / (1 - abs(2 * lightness - 1)), lightness)
    }

    /// WCAG's relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func mixed(with other: PlainColor, _ part: Double) -> PlainColor {
        PlainColor(
            red: red + (other.red - red) * part, green: green + (other.green - green) * part, blue: blue + (other.blue - blue) * part)
    }
}

/// The colours of a page, made from a picture's: always ones that text can be read on.
///
/// The colours lie over each other as gradients, so it is their mixtures that have to be
/// readable. Luminance curves upwards over the stored values: a mixture is never lighter than
/// the lightest of what it is made of, but it can be darker than the darkest. Dark pages
/// therefore keep each colour under a limit, and light ones the darkest channels together above
/// one.
///
/// Dark and bright pages also stay clean. A dark yellow is olive, so it becomes gold or green;
/// and two hues whose mixtures are olive or grey are brought together until they are not.
struct ArtworkColors: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        case dark, light
        /// A tile with white on it, in both appearances: fuller than a page.
        case tile
        /// The kids screens, and those with more contrast.
        case kids, kidsDeep
    }

    /// White on it is 7:1.
    static let kidsLimit = 1.05 / 7 - 0.05
    /// White on it is 9:1.
    static let kidsDeepLimit = 1.05 / 9 - 0.05
    /// White on a tile is 4.5:1.
    static let tileLimit = 1.05 / 4.5 - 0.05
    /// The second text colour and the accent are 4.5:1 on it.
    static let darkLimit = 0.035
    static let lightLimit = 0.82

    var base: PlainColor
    /// What the page starts with at its top, and runs out of into the base.
    var top: PlainColor
    /// From the top right, the bottom left and the bottom right.
    var glows: [PlainColor]
    /// The sidebar beside the page: the app's own colour with a little of the page's.
    var sidebar: PlainColor
    /// A quiet control on the page.
    var panel: PlainColor

    /// nil for a picture without colour: the app's own colours are used.
    init?(_ palette: ArtworkPalette, style: Style) {
        let leads = [.dark, .kids, .kidsDeep].contains(style) ? Self.forTheDark(palette.leads) : palette.leads
        guard let first = leads.first else { return nil }
        let second = leads.dropFirst().first ?? first
        let third = leads.dropFirst(2).first ?? second
        switch style {
        case .dark:
            func dark(_ lead: ArtworkPalette.Lead, _ lightness: Double, _ saturation: Double) -> PlainColor {
                guard Self.isWarm(lead.hue) || Self.isRed(lead.hue) else {
                    return PlainColor(
                        hue: Self.cleanHue(lead.hue), saturation: min(lead.saturation, saturation), lightness: lightness
                    ).darkened(to: Self.darkLimit)
                }
                // A dark orange is a brown and a dark red a warning: both are a wine here.
                return PlainColor(hue: Self.wine(lead.hue), saturation: saturation * 0.92, lightness: lightness * 0.95)
                    .darkened(to: Self.darkLimit)
            }
            base = dark(first, 0.085, 0.34)
            glows = Self.together(
                base: first, glows: [first, second, third], lightness: [0.21, 0.17, 0.14], saturation: [0.58, 0.5, 0.42], make: dark,
                baseLightness: 0.085, baseSaturation: 0.34)
            top = dark(first, 0.2, 0.56)
            sidebar = PlainColor(red: 0x14 / 255, green: 0x0E / 255, blue: 0x20 / 255).mixed(with: dark(first, 0.08, 0.36), 0.6)
            panel = dark(first, 0.19, 0.32)
        case .tile:
            func full(_ lead: ArtworkPalette.Lead, _ lightness: Double) -> PlainColor {
                let hue = Self.cleanHue(lead.hue, warmth: Self.deepWarmth)
                return PlainColor(hue: hue, saturation: min(0.62, max(0.4, lead.saturation)), lightness: lightness).darkened(to: Self.tileLimit)
            }
            base = full(first, 0.2)
            glows = [full(first, 0.36), full(first, 0.28), full(first, 0.28)]
            top = glows[0]
            sidebar = base
            panel = base
        case .light:
            func pale(_ lead: ArtworkPalette.Lead, _ lightness: Double, _ saturation: Double) -> PlainColor {
                PlainColor(hue: lead.hue, saturation: min(lead.saturation, saturation), lightness: lightness)
            }
            var all = [
                pale(first, 0.965, 0.5), pale(first, 0.9, 0.75), pale(second, 0.92, 0.7), pale(third, 0.93, 0.65), pale(first, 0.895, 0.75),
            ]
            func darkest() -> PlainColor {
                PlainColor(red: all.map(\.red).min()!, green: all.map(\.green).min()!, blue: all.map(\.blue).min()!)
            }
            while darkest().luminance < Self.lightLimit {
                all = all.map { $0.mixed(with: PlainColor(red: 1, green: 1, blue: 1), 0.02) }
            }
            base = all[0]
            glows = Array(all[1...3])
            top = all[4]
            sidebar = PlainColor(red: 0xEF / 255, green: 0xEA / 255, blue: 0xF2 / 255).mixed(with: base, 0.5)
            panel = PlainColor(red: 1, green: 1, blue: 1)
        case .kids, .kidsDeep:
            // The dark page's colours, let up into the light as far as white stays readable.
            let isDeep = style == .kidsDeep
            let shade = isDeep ? 0.6 : 1.0, limit = isDeep ? Self.kidsDeepLimit : Self.kidsLimit
            func rich(_ lead: ArtworkPalette.Lead, _ lightness: Double, _ saturation: Double) -> PlainColor {
                let isWarm = Self.isWarm(lead.hue) || Self.isRed(lead.hue)
                let hue = isWarm ? Self.wine(lead.hue) : Self.cleanHue(lead.hue)
                return PlainColor(hue: hue, saturation: min(saturation, max(0.5, lead.saturation)), lightness: lightness * shade)
                    .darkened(to: limit)
            }
            base = rich(first, 0.15, 0.5)
            glows = Self.together(
                base: first, glows: [second, third, first], lightness: [0.36, 0.3, 0.26], saturation: [0.62, 0.58, 0.56], make: rich,
                baseLightness: 0.15, baseSaturation: 0.5)
            top = rich(first, 0.31, 0.58)
            sidebar = base
            panel = rich(first, 0.24, 0.5)
        }
    }

    // MARK: Clean hues

    /// Yellow and yellow-green, which go olive in the dark, as gold or as green.
    ///
    /// - Parameter warmth: Under 1, orange and gold are brought towards red by that much: deep,
    ///   they are browns.
    static func cleanHue(_ hue: Double, warmth: Double = 1) -> Double {
        var degrees = hue * 360
        if degrees > 42, degrees < 100 { degrees = degrees < 55 ? 40 : 112 }
        return (degrees <= 42 ? degrees * warmth : degrees) / 360
    }

    /// Red to yellow as the wine a dark page has for it: the app's own side of red.
    static func wine(_ hue: Double) -> Double {
        (340 + (isRed(hue) ? 0 : hue * 360 * 0.15)) / 360
    }

    /// For a dark page the cool colours of a picture count more: skin, wood and lamps are in
    /// nearly every picture, and every page would be red.
    static func forTheDark(_ leads: [ArtworkPalette.Lead]) -> [ArtworkPalette.Lead] {
        func part(_ place: Int) -> Double { (leads[place].weight ?? 1 / Double(place + 1)) * (isWarm(leads[place].hue) || isRed(leads[place].hue) ? 0.35 : 1) }
        return leads.indices.sorted { (part($0), $1) > (part($1), $0) }.map { leads[$0] }
    }

    static let deepWarmth = 0.5

    /// The reds below where the hues start.
    private static func isRed(_ hue: Double) -> Bool {
        hue * 360 >= 345
    }

    private static func isWarm(_ hue: Double) -> Bool {
        hue * 360 < 55
    }

    /// Whether a mixture of two colours is neither olive nor grey anywhere on the way.
    static func mixCleanly(_ one: PlainColor, _ other: PlainColor) -> Bool {
        let least = min(one.chroma, other.chroma)
        return stride(from: 0.1, to: 0.95, by: 0.1).allSatisfy { part in
            let mixture = one.mixed(with: other, part)
            return mixture.chroma >= 0.6 * least && !mixture.isOlive
        }
    }

    /// The glows, each turned towards the base until it mixes cleanly with the base and with
    /// the glows before it.
    private static func together(
        base: ArtworkPalette.Lead, glows: [ArtworkPalette.Lead], lightness: [Double], saturation: [Double],
        make: (ArtworkPalette.Lead, Double, Double) -> PlainColor, baseLightness: Double = 0.11, baseSaturation: Double = 0.3
    ) -> [PlainColor] {
        var placed = [make(base, baseLightness, baseSaturation)]
        let home = cleanHue(base.hue)
        for (index, glow) in glows.enumerated() {
            let start = cleanHue(glow.hue)
            var turn = home - start
            if turn > 0.5 { turn -= 1 }
            if turn < -0.5 { turn += 1 }
            var chosen = make(base, lightness[index], saturation[index])
            for step in 0..<20 {
                let hue = start + turn * Double(step) / 20
                let lead = ArtworkPalette.Lead(hue: hue - hue.rounded(.down), saturation: glow.saturation)
                let candidate = make(lead, lightness[index], saturation[index])
                if placed.allSatisfy({ mixCleanly($0, candidate) }) {
                    chosen = candidate
                    break
                }
            }
            placed.append(chosen)
        }
        return Array(placed.dropFirst())
    }
}

extension PlainColor {
    /// A yellow or yellow-green with enough colour to see, as it looks when it is not light.
    var isOlive: Bool {
        let (hue, saturation, _) = hsl
        return saturation > 0.08 && hue * 360 > 46 && hue * 360 < 98
    }

    /// The same hue, so dark that its luminance is at most `limit`.
    func darkened(to limit: Double) -> PlainColor {
        var color = self
        while color.luminance > limit { color = color.mixed(with: PlainColor(red: 0, green: 0, blue: 0), 0.01) }
        return color
    }
}
