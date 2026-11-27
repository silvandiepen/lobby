// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// How one viewer wants subtitles: on in which languages, forced subtitles, size and background.
/// Each change is sent at once; the player goes by it from the next film on.
struct SubtitleSettingsView: View {
    @Environment(AppModel.self) private var app
    let profileID: String
    @State private var problem: String?

    private var preferences: SubtitlePreferences {
        app.profiles.first { $0.id == profileID }?.subtitlePreferences ?? .defaults
    }

    var body: some View {
        LobbyForm {
            Section {
                if preferences.languages.isEmpty {
                    Text("Off")
                        .foregroundStyle(.lobbySecondary)
                        .accessibilityIdentifier("subtitles.off")
                }
                ForEach(Array(preferences.languages.enumerated()), id: \.element) { position, code in
                    Menu {
                        if position > 0 {
                            Button("Move Up", systemImage: "arrow.up") { change { $0.languages.swapAt(position, position - 1) } }
                        }
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            change { $0.languages.remove(at: position) }
                        }
                    } label: {
                        LabeledContent(SubtitleLanguages.name(code), value: position == 0 ? "First" : "")
                    }
                    .accessibilityIdentifier("subtitles.language.\(code)")
                }
                Menu("Add a Language…") {
                    ForEach(SubtitleLanguages.choices(excluding: preferences.languages), id: \.self) { code in
                        Button(SubtitleLanguages.name(code)) { change { $0.languages.append(code) } }
                    }
                }
                .accessibilityIdentifier("subtitles.add")
            } header: {
                Text("Languages")
            } footer: {
                Text("A film starts with subtitles in the first of these languages it has. With none, subtitles are off. The player's menu still offers the others.")
            }
            Section {
                Toggle("Forced Subtitles (Foreign Speech)", isOn: binding(\.forced))
                    .accessibilityIdentifier("subtitles.forced")
            } footer: {
                Text("Only the lines for speech in another language, when a film has them, also with subtitles off.")
            }
            Section("Look") {
                Picker("Size", selection: binding(\.size)) {
                    Text("Small").tag(SubtitlePreferences.Size.small)
                    Text("Medium").tag(SubtitlePreferences.Size.medium)
                    Text("Large").tag(SubtitlePreferences.Size.large)
                }
                .accessibilityIdentifier("subtitles.size")
                Toggle("Dark Background", isOn: binding(\.background))
                    .accessibilityIdentifier("subtitles.background")
            }
            if let problem {
                Section {
                    Text(problem).foregroundStyle(Color.lobbyFailure)
                }
            }
        }
        .navigationTitle("Subtitles")
    }

    private func binding<Value>(_ path: WritableKeyPath<SubtitlePreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: path] }, set: { value in change { $0[keyPath: path] = value } })
    }

    private func change(_ edit: (inout SubtitlePreferences) -> Void) {
        var changed = preferences
        edit(&changed)
        guard changed != preferences else { return }
        Task {
            do {
                try await app.setSubtitlePreferences(changed, profileID: profileID)
                problem = nil
            } catch {
                problem = await app.managerProblem(error)
            }
        }
    }
}

/// The languages the settings offer, by name.
enum SubtitleLanguages {
    /// The household's and the most common ones, then the device's own.
    static let common = ["nl", "en", "hy", "ru", "de", "fr", "es", "it", "pt", "tr", "ar", "pl", "uk", "zh", "ja", "ko"]

    static func choices(excluding chosen: [String]) -> [String] {
        let device = Locale.preferredLanguages.compactMap(SubtitleLanguage.base)
        var all: [String] = []
        for code in device + common where !all.contains(code) { all.append(code) }
        let taken = Set(chosen.compactMap(SubtitleLanguage.base))
        return all.filter { !taken.contains($0) }
    }

    /// "Dutch", in the device's language; the code itself when it has no name.
    static func name(_ code: String) -> String {
        guard let name = Locale.current.localizedString(forLanguageCode: SubtitleLanguage.base(code) ?? code) else { return code }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "Off", "Dutch, English".
    static func summary(_ preferences: SubtitlePreferences) -> String {
        preferences.isOff ? "Off" : preferences.languages.map(name).joined(separator: ", ")
    }
}
