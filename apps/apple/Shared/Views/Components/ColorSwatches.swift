// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// One of the API's colours, or none where that may be chosen. As many swatches on a row as
/// fit; the rest wrap to the next row.
struct ColorSwatches: View {
    let colors: [String]
    @Binding var selection: String?
    var allowsNone = false
    /// Before the colour's name in the accessibility identifier.
    let identifier: String
    @Environment(\.motion) private var motion

    #if os(iOS)
    private static let side: CGFloat = 44
    #else
    private static let side: CGFloat = 36
    #endif

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.side, maximum: 44), spacing: AppTheme.Space.xs)],
            alignment: .leading, spacing: AppTheme.Space.s
        ) {
            if allowsNone {
                swatch(nil)
            }
            ForEach(colors, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ option: String?) -> some View {
        Button {
            selection = option
        } label: {
            ZStack {
                if let option {
                    Circle().fill(Color.lobbyProfile(option))
                    if option == selection {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.lobbyOnArtwork)
                    }
                } else {
                    Image(systemName: selection == nil ? "circle.slash.fill" : "circle.slash")
                        .font(.title)
                        .foregroundStyle(selection == nil ? .primary : .secondary)
                }
            }
            .frame(width: 32, height: 32)
            .frame(minWidth: Self.side, minHeight: Self.side)
            .animation(motion.animation(.change), value: selection)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lobbyPill)
        .accessibilityLabel(option?.capitalized ?? "No colour")
        .accessibilityAddTraits(option == selection ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).\(option ?? "none")")
    }
}
