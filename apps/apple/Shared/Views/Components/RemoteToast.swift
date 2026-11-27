// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// "Played from Alex's iPhone", for a moment after another device started something here.
struct RemoteToastView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            if let text = app.remote.toast {
                Label(text, systemImage: AppSymbol.playOn)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, AppTheme.Space.l)
                    .padding(.vertical, AppTheme.Space.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(AppTheme.Space.xl)
                    .transition(.opacity)
                    .accessibilityIdentifier("remote.toast")
            }
        }
        .animation(motion.animation(.list), value: app.remote.toast)
        .allowsHitTesting(false)
    }
}
