// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Settings → Server → Speakers: the HomePods and AirPlay speakers Lobby Server plays music and
/// stories to. Found by themselves; a manager names them, hides them, or gives one its password.
struct SpeakersView: View {
    @State private var model: SpeakersModel
    @State private var renaming: ManagedSpeaker?
    @State private var newName = ""
    @State private var passwordFor: ManagedSpeaker?
    @State private var password = ""

    init(app: AppModel) {
        _model = State(initialValue: SpeakersModel(app: app))
    }

    var body: some View {
        LobbyForm {
            if model.status != nil, !model.isUnavailable {
                switchSection
                if model.isConfigured, model.isEnabled {
                    speakersSection
                }
            }
        }
        .overlay {
            if model.isUnavailable {
                ContentUnavailableView(
                    "Not on this server", systemImage: "homepod.and.homepodmini",
                    description: Text("This Lobby Server cannot play on speakers yet. Update it first."))
            } else if model.status == nil, model.problem == nil {
                ProgressView()
            }
        }
        .navigationTitle("Speakers")
        .task { await model.watch() }
        .refreshable { await model.load() }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .alert(
            "Name \(renaming?.foundName ?? "")",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Name", text: $newName)
                .accessibilityIdentifier("speakers.name")
            Button("Save") {
                if let speaker = renaming { Task { await model.rename(speaker, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("As it is called in Play On. Leave it empty for its own name.")
        }
        .alert(
            "Password for \(passwordFor?.name ?? "")",
            isPresented: Binding(get: { passwordFor != nil }, set: { if !$0 { passwordFor = nil } })
        ) {
            SecureField("Password", text: $password)
                .accessibilityIdentifier("speakers.password")
            Button("Save") {
                if let speaker = passwordFor { Task { await model.setPassword(speaker, password) } }
                passwordFor = nil
                password = ""
            }
            Button("Cancel", role: .cancel) {
                passwordFor = nil
                password = ""
            }
        } message: {
            Text("The one set for it in the Home app or on the speaker. Lobby Server keeps it with the Apple TVs’ credentials, readable only by itself. Leave it empty to remove it.")
        }
    }

    private var switchSection: some View {
        Section {
            Toggle(
                "Play on HomePods and Speakers",
                isOn: Binding(get: { model.isEnabled }, set: { on in Task { await model.setEnabled(on) } })
            )
            .disabled(model.isWorking || !model.isConfigured)
            .accessibilityIdentifier("speakers.enabled")
            Text(model.summary)
                .foregroundStyle(.lobbySecondary)
                .accessibilityIdentifier("speakers.status")
        } footer: {
            Text("Play On offers the HomePods and AirPlay speakers on Lobby Server’s network for music and stories. Lobby Server plays to them itself, so the phone can be closed or leave. A child can play on them only as itself, and only while it may listen. A HomePod plays for Lobby Server when the Home app allows speaker access to everyone on the same network.")
        }
    }

    private var speakersSection: some View {
        Section {
            ForEach(model.speakers) { speaker in
                row(speaker)
            }
            Button {
                Task { await model.scan() }
            } label: {
                Label(model.isScanning ? "Looking…" : "Look Again", systemImage: AppSymbol.refresh)
            }
            .disabled(model.isScanning || model.status?.running != true)
            .accessibilityIdentifier("speakers.scan")
        } header: {
            Label("On This Network", systemImage: "homepod.and.homepodmini")
        } footer: {
            Text("Lobby Server looks for speakers every minute by itself. Apple TVs and Macs are not here: they are in Play On as themselves.")
        }
    }

    private func row(_ speaker: ManagedSpeaker) -> some View {
        HStack(spacing: AppTheme.Space.m) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name)
                    Text(SpeakersModel.state(of: speaker))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            } icon: {
                Image(systemName: speaker.kind == .homepod ? "homepod.fill" : "hifispeaker.fill")
                    .foregroundStyle(.lobbySecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("speakers.speaker.\(speaker.foundName)")
            Spacer(minLength: 0)
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newName = speaker.name
                    renaming = speaker
                }
                Button(speaker.hidden ? "Show in Play On" : "Hide from Play On", systemImage: speaker.hidden ? "eye" : "eye.slash") {
                    Task { await model.setHidden(speaker, !speaker.hidden) }
                }
                Button(speaker.hasPassword ? "Change Password" : "Enter Password", systemImage: "key") {
                    password = ""
                    passwordFor = speaker
                }
                .disabled(!speaker.found)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .menuStyle(.button)
            .buttonStyle(.lobbyIcon)
            .disabled(model.isWorking)
            .accessibilityLabel("Change \(speaker.name)")
            .accessibilityIdentifier("speakers.menu.\(speaker.foundName)")
        }
    }
}
