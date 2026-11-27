// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import LobbyKit

/// How a category or a part of the library looks: the household's own choice, from the
/// server. Nothing here is decided by the app from a name.
struct CategoryLook: Hashable, Sendable {
    /// An SF Symbol the household chose. nil: the neutral one.
    var symbol: String?
    /// One of the API's colour names. nil: the app's own choice by place.
    var color: String?
    /// A logo that stands for the name.
    var logo: CategoryLogo?

    static let plain = CategoryLook()

    init(symbol: String? = nil, color: String? = nil, logo: CategoryLogo? = nil) {
        self.symbol = symbol
        self.color = color
        self.logo = logo
    }

    /// The look of a category, from what the server said about the household's categories.
    init(category id: String, in groups: CategoryGroups) {
        let category = groups.category(id: id)
        self.init(symbol: category?.icon, color: category?.color, logo: category?.logo)
    }

    /// The look of a part of the library.
    init(group id: String, in groups: CategoryGroups) {
        let group = groups.group(id: id)
        self.init(symbol: group?.icon, color: group?.color, logo: group?.logo)
    }
}

/// Sizes for logos that are shown side by side.
enum LogoMetrics {
    /// A size for a logo of `width` by `height` pixels that covers about the same area as
    /// every other logo sized with the same `area`: a wide, low wordmark gets wider and
    /// lower, a compact mark taller, so none of them looks heavier than its neighbour.
    /// Never wider than `maxWidth` nor higher than `maxHeight`.
    static func size(width: Int, height: Int, area: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard width > 0, height > 0, area > 0 else { return .zero }
        let ratio = CGFloat(width) / CGFloat(height)
        var h = (area / ratio).squareRoot()
        var w = h * ratio
        if w > maxWidth {
            w = maxWidth
            h = w / ratio
        }
        if h > maxHeight {
            h = maxHeight
            w = h * ratio
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}
