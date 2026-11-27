// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// A thin bar: how far the viewer is.
struct ProgressBar: View {
    let fraction: Double
    let track: Color
    let fill: Color
    var height: CGFloat = 3
    @Environment(\.motion) private var motion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(height, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(motion.animation(.list), value: fraction)
        .accessibilityHidden(true)
    }
}
