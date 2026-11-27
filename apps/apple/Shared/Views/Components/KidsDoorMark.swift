// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// The kids icon's picture, the door with sparkles in its light (Brand/portal-kids.png, drawn into
/// Brand.xcassets by Scripts/make-icons.py): the mark of the kids screens. Used sparingly, where
/// it says "this is the kids' side": the kids home, their calm pages, a kids viewer on Who is
/// watching, and the kids part of Settings. Decoration only: VoiceOver passes over it.
struct KidsDoorMark: View {
    var size: CGFloat

    var body: some View {
        Image("KidsDoor")
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
