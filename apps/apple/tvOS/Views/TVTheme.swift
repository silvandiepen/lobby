// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Sizes for a screen that is read from the sofa, on tvOS's 1920 by 1080 points.
enum TVMetrics {
    static let poster: CGFloat = 248
    static let wide: CGFloat = 600
    static let still: CGFloat = 340
    static let gap: CGFloat = 40
    static let shelfGap: CGFloat = 56
    static let viewer: CGFloat = 250
    static let kidsPoster: CGFloat = 300
    static let kidsWide: CGFloat = 540
    /// A line of text that can be read without turning the head.
    static let readable: CGFloat = 1100
}

/// A message with a symbol, large: what happened and what to do about it.
struct TVNotice: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.l) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Space.xl)
        .frame(maxWidth: TVMetrics.readable, alignment: .leading)
        .lobbyPanel()
        .accessibilityElement(children: .combine)
    }
}

/// A button's words, with a spinner beside them while it is at work.
struct TVWorkingLabel: View {
    let title: String
    let symbol: String
    let isWorking: Bool
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: AppTheme.Space.m) {
            if isWorking {
                ProgressView().transition(.opacity)
            } else {
                Image(systemName: symbol).accessibilityHidden(true).transition(.opacity)
            }
            Text(title)
        }
        .animation(motion.animation(.change), value: isWorking)
    }
}

/// Seconds since a view appeared, for saying that something takes long.
struct WaitedReader<Content: View>: View {
    @ViewBuilder var content: (Double) -> Content
    @State private var since = Date()

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            content(max(0, context.date.timeIntervalSince(since)))
        }
    }
}
