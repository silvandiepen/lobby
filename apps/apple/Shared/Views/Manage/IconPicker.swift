// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// Chooses a symbol: from suggestions, from groups, or by searching for a word or a symbol's
/// own name. Nothing is set without a tap, and a tap is all it takes.
struct IconPicker: View {
    @Binding var selection: String?
    /// From the name and the titles of what the icon is for.
    let suggestions: [String]
    @State var query = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @FocusState private var isTyping: Bool

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        LobbySheet(title: "Icon", width: 560, height: 600) {
            VStack(spacing: 0) {
                field
                    .padding(.horizontal, AppTheme.Space.l)
                    .padding(.vertical, AppTheme.Space.s)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Space.l) {
                        if typed.isEmpty {
                            choices
                        } else {
                            results
                        }
                    }
                    .padding(.horizontal, AppTheme.Space.l)
                    .padding(.vertical, AppTheme.Space.s)
                }
            }
            .background(Color.lobbyBackground(scheme))
        }
    }

    private var field: some View {
        HStack(spacing: AppTheme.Space.s) {
            Image(systemName: AppSymbol.search)
                .foregroundStyle(.lobbySecondary)
                .accessibilityHidden(true)
            TextField("Search icons", text: $query, prompt: Text("Search, or type a symbol’s name").foregroundStyle(.lobbySecondary))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .focused($isTyping)
                .accessibilityIdentifier("icon.search")
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.lobbyIcon)
                    .foregroundStyle(.lobbySecondary)
                    .accessibilityIdentifier("icon.clear")
            }
        }
        .padding(.horizontal, AppTheme.Space.m)
        .frame(minHeight: 36)
        .background(Color.lobbySurfaceRaised(scheme), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { isTyping = true }
    }

    @ViewBuilder
    private var choices: some View {
        panel("Suggestions") {
            if suggestions.isEmpty {
                Text("Give it a name, and icons that fit it are suggested here.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            } else {
                grid(suggestions, identifier: "icon.suggestion")
            }
        }
        if selection != nil {
            Button("No Icon", systemImage: AppSymbol.noMatch) { choose(nil) }
                .buttonStyle(.lobbyText)
                .accessibilityIdentifier("icon.none")
        }
        ForEach(SymbolCatalog.groups) { group in
            panel(group.title) {
                grid(group.entries.map(\.symbol), identifier: "icon.choice")
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let found = SymbolSearch.results(for: typed)
        if found.isEmpty {
            ContentUnavailableView {
                Label("No icon for “\(typed)”", systemImage: AppSymbol.search)
            } description: {
                Text("Try another word, in English or Dutch, or the full name of an SF Symbol, such as star.fill.")
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("icon.empty")
        } else {
            panel(found.count == 1 ? "1 icon" : "\(found.count) icons") {
                grid(found, identifier: "icon.result")
            }
        }
    }

    private func grid(_ symbols: [String], identifier: String) -> some View {
        IconGrid(symbols: symbols, selection: selection, identifier: identifier) { choose($0) }
    }

    private func choose(_ name: String?) {
        selection = name
        dismiss()
    }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.lobbySecondary)
                .accessibilityAddTraits(.isHeader)
            content()
                .padding(AppTheme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.lobbySurface(scheme), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        }
    }
}

/// Symbols to tap, as many on a row as fit.
struct IconGrid: View {
    let symbols: [String]
    let selection: String?
    /// Before the symbol's name in the accessibility identifier.
    let identifier: String
    let choose: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .title3) private var side: CGFloat = 44

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: side, maximum: side * 1.4), spacing: AppTheme.Space.xs)],
            alignment: .leading, spacing: AppTheme.Space.xs
        ) {
            ForEach(symbols, id: \.self) { name in
                let isSelected = name == selection
                Button {
                    choose(name)
                } label: {
                    Image(systemName: name)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.lobbyAccent(scheme) : .primary)
                        .frame(width: side, height: side)
                        .background(
                            isSelected ? Color.lobbySelection(scheme) : .clear,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lobbyPill)
                .help(name)
                .accessibilityLabel(SymbolCatalog.spokenName(of: name))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(name)")
            }
        }
    }
}
