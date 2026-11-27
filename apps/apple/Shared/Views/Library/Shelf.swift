// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// A titled row that scrolls sideways, with See all when there is a full list to go to.
struct Shelf<Content: View>: View {
    let title: String
    /// A quiet word about how the row is made.
    var note: String? = nil
    /// A category's or group's own look: its logo stands for the title.
    var look: CategoryLook? = nil
    var seeAll: Route? = nil
    @ViewBuilder var content: Content

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let margin = TileMetrics.margin(sizeClass)
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                if let look, look.logo != nil {
                    LogoOrText(title: title, look: look, area: 1_900, maxWidth: 150, maxHeight: 30) { words }
                } else {
                    words
                }
                Spacer()
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        HStack(spacing: AppTheme.Space.xs) {
                            Text("See all")
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityLabel("See all \(title)")
                }
            }
            .padding(.horizontal, margin)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TileMetrics.gap(sizeClass)) {
                    content
                }
                .scrollTargetLayout()
            }
            .modifier(ShelfScrolling(margin: margin))
        }
        .rowEase()
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
    }
}
