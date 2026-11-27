// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// What happens when something ends, for one viewer: suggestions after a film, the next
/// episode by itself, "Still watching?". The viewer's own, on every device they watch on; a
/// kids viewer's is set here by a grown-up (a manager). Each change is sent at once.
struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var app
    let profileID: String
    @State private var problem: String?

    private var profile: Profile? { app.profiles.first { $0.id == profileID } }
    private var preferences: PlaybackPreferences { profile?.playbackPreferences ?? .defaults }

    var body: some View {
        LobbyForm {
            Section {
                Toggle("Next Episode Automatically", isOn: binding(\.episodeAutoplay))
                    .accessibilityIdentifier("playback.episodeAutoplay")
                Picker("Countdown", selection: binding(\.countdownSeconds)) {
                    ForEach(PlaybackPreferences.countdownChoices, id: \.self) { seconds in
                        Text(PlaybackWords.countdown(seconds)).tag(seconds)
                    }
                }
                .accessibilityIdentifier("playback.countdown")
                Toggle("Start Next at the Credits", isOn: binding(\.startAtCredits))
                    .accessibilityIdentifier("playback.startAtCredits")
            } header: {
                Text("Series")
            } footer: {
                Text("At the end of an episode the next one starts after the countdown, also from the last of a season into the next. With the countdown off, Up Next waits for Play Now. Lobby Server does not know where credits begin yet: until it does, Up Next comes at the end.")
            }
            Section {
                Toggle("Suggestions", isOn: binding(\.filmSuggestions))
                    .accessibilityIdentifier("playback.filmSuggestions")
                Toggle("Play a Suggestion Automatically", isOn: binding(\.filmAutoplay))
                    .disabled(!preferences.filmSuggestions)
                    .accessibilityIdentifier("playback.filmAutoplay")
            } header: {
                Text("Films")
            } footer: {
                Text("When a film or a whole series is over, what goes with it and what you were watching. Nothing starts by itself unless you turn that on.")
            }
            Section {
                Picker("After Episodes in a Row", selection: binding(\.stillWatchingEpisodes)) {
                    ForEach(PlaybackPreferences.stillWatchingEpisodeChoices, id: \.self) { count in
                        Text(PlaybackWords.episodes(count)).tag(count)
                    }
                }
                .accessibilityIdentifier("playback.stillWatchingEpisodes")
                Picker("After Hours", selection: binding(\.stillWatchingHours)) {
                    ForEach(PlaybackPreferences.stillWatchingHourChoices, id: \.self) { hours in
                        Text(PlaybackWords.hours(hours)).tag(hours)
                    }
                }
                .accessibilityIdentifier("playback.stillWatchingHours")
            } header: {
                Text("Still Watching?")
            } footer: {
                Text("Before something starts by itself, Lobby asks whether anyone is still watching, and waits. Pausing, skipping or any button, also on a remote, starts the count again.")
            }
            if let problem {
                Section {
                    Text(problem).foregroundStyle(Color.lobbyFailure)
                }
            }
        }
        .navigationTitle("Playback")
    }

    private func binding<Value>(_ path: WritableKeyPath<PlaybackPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: path] }, set: { value in change { $0[keyPath: path] = value } })
    }

    private func change(_ edit: (inout PlaybackPreferences) -> Void) {
        var changed = preferences
        edit(&changed)
        guard changed != preferences else { return }
        Task {
            do {
                try await app.setPlaybackPreferences(changed, profileID: profileID)
                problem = nil
            } catch {
                problem = await app.managerProblem(error)
            }
        }
    }
}
