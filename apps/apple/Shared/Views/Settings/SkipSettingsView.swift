// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// What one viewer wants at intros and credits: a Skip Intro button, skipping by itself, or
/// nothing; Next Episode when the credits start, or nothing. Each change is sent at once.
struct SkipSettingsView: View {
    let profileID: String

    var body: some View {
        LobbyForm {
            SkipSettingsSection(profileID: profileID)
        }
        .navigationTitle("Intros and Credits")
    }
}

/// The two choices, for the viewer's own settings and for a grown-up on a viewer's page.
struct SkipSettingsSection: View {
    @Environment(AppModel.self) private var app
    let profileID: String
    @State private var problem: String?

    private var preferences: SkipPreferences {
        app.profiles.first { $0.id == profileID }?.skipPreferences ?? .defaults
    }

    var body: some View {
        Section {
            Picker("Intros", selection: binding(\.intro)) {
                ForEach(SkipPreferences.Intro.allCases, id: \.self) { choice in
                    Text(SkipWords.intro(choice)).tag(choice)
                }
            }
            .accessibilityIdentifier("skipping.intro")
            Picker("Credits", selection: binding(\.credits)) {
                ForEach(SkipPreferences.Credits.allCases, id: \.self) { choice in
                    Text(SkipWords.credits(choice)).tag(choice)
                }
            }
            .accessibilityIdentifier("skipping.credits")
            if let problem {
                Text(problem).foregroundStyle(Color.lobbyFailure)
            }
        } header: {
            Text("Intros and Credits")
        } footer: {
            Text("Where an episode's intro and credits are is read from the file, or found by comparing the episodes of a season. Not every title has them.")
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<SkipPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: path] }, set: { value in
            var changed = preferences
            changed[keyPath: path] = value
            guard changed != preferences else { return }
            Task {
                do {
                    try await app.setSkipPreferences(changed, profileID: profileID)
                    problem = nil
                } catch {
                    problem = await app.managerProblem(error)
                }
            }
        })
    }
}

/// The words for the choices.
enum SkipWords {
    static func intro(_ choice: SkipPreferences.Intro) -> String {
        switch choice {
        case .show: "Show Skip Intro"
        case .skip: "Skip Automatically"
        case .off: "Off"
        }
    }

    static func credits(_ choice: SkipPreferences.Credits) -> String {
        switch choice {
        case .show: "Show Next Episode"
        case .off: "Off"
        }
    }

    /// "Show Skip Intro", "Skip Automatically", "Off".
    static func summary(_ preferences: SkipPreferences) -> String {
        intro(preferences.intro)
    }
}
