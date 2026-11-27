// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Who is watching? Each viewer has their own Continue Watching and resume positions.
struct ProfilePickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var isAdding = false
    /// Pressing a viewer changes their picture, until Done.
    @State private var isChoosingPictures = false
    @State private var picking: Profile?
    @Environment(\.motion) private var motion
    @ScaledMetric(relativeTo: .title2) private var avatarSize: CGFloat = 96

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Space.xl) {
                VStack(spacing: AppTheme.Space.s) {
                    Text(isChoosingPictures ? "Whose picture?" : "Who is watching?")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    ServerSwitcherButton()
                }
                .padding(.top, AppTheme.Space.xl * 2)

                if app.profiles.isEmpty {
                    empty
                } else {
                    // A few viewers stand in a row in the middle; a large household wraps.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: AppTheme.Space.xl) {
                            viewers
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: avatarSize + AppTheme.Space.l), spacing: AppTheme.Space.l)],
                            spacing: AppTheme.Space.xl
                        ) {
                            viewers
                        }
                    }
                }

                if app.offersAvatars, !app.profiles.isEmpty {
                    Button(isChoosingPictures ? "Done" : "Choose Pictures", systemImage: isChoosingPictures ? AppSymbol.done : AppSymbol.picture) {
                        isChoosingPictures.toggle()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("profile.pictures")
                }

                if app.isManager && app.hasFetchedProfiles {
                    Button("Add a Viewer", systemImage: "plus") { isAdding = true }
                        .buttonStyle(QuietButtonStyle())
                        .frame(maxWidth: 280)
                        .accessibilityIdentifier("profile.add")
                }
            }
            .frame(maxWidth: AppTheme.readableWidth)
            .padding(AppTheme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .background(Color.lobbyBackground(scheme))
        .task { await app.watchProfiles() }
        .sheet(isPresented: $isAdding) {
            AddProfileView()
        }
        .sheet(item: $picking) { AvatarPickerSheet(app: app, profileID: $0.id) }
        .animation(motion.animation(.change), value: isChoosingPictures)
    }

    private var viewers: some View {
        ForEach(app.profiles) { profile in
            Button {
                if isChoosingPictures {
                    picking = profile
                } else {
                    Task { await app.selectProfile(profile) }
                }
            } label: {
                VStack(spacing: AppTheme.Space.m) {
                    ProfileAvatar(profile: profile, size: avatarSize)
                        .overlay(alignment: .bottomTrailing) {
                            if isChoosingPictures {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.lobbyProminentLabel(scheme), Color.lobbyProminentFill(scheme))
                                    .transition(motion.moves ? .scale.combined(with: .opacity) : .opacity)
                                    .accessibilityHidden(true)
                            } else if profile.kids != nil {
                                KidsDoorMark(size: avatarSize * 0.34)
                            }
                        }
                    Text(profile.name)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: avatarSize + AppTheme.Space.l)
                }
            }
            .buttonStyle(TileButtonStyle(lifts: false))
            .accessibilityLabel(isChoosingPictures ? "\(profile.name), choose a picture" : profile.name)
            .accessibilityIdentifier("profile.\(profile.name)")
        }
    }

    @ViewBuilder
    private var empty: some View {
        if app.connectivity == .offline {
            NoticeView(
                symbol: "wifi.slash", tint: Color.lobbyWarning, title: "Lobby Server cannot be reached",
                text: "The viewers could not be fetched. Check the network and try again.")
            Button("Try Again", systemImage: AppSymbol.refresh) { Task { await app.fetchProfiles() } }
                .buttonStyle(QuietButtonStyle())
                .frame(maxWidth: 280)
        } else if !app.hasFetchedProfiles {
            ProgressView("Fetching the viewers…")
        } else {
            NoticeView(
                symbol: "person.2.fill", tint: NavigationTint.series, title: "There are no viewers yet",
                text: app.isManager
                    ? "Add one for each person who watches, so everyone keeps their own place."
                    : "A manager adds viewers, one for each person who watches. This device was paired as a viewer and cannot add them.")
            .accessibilityIdentifier("profile.none")
        }
    }
}

/// A manager adds a viewer: a name, a colour and a picture.
struct AddProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "blue"
    @State private var avatar: String?
    @State private var isPicking = false
    @State private var isKids = false
    @State private var failure: String?
    @State private var isSaving = false
    @FocusState private var nameIsFocused: Bool
    @Environment(\.colorScheme) private var scheme

    static let colors = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]

    private var canAdd: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        #if os(macOS)
        // A Mac sheet: its own margins, the title at the top, the buttons at the bottom right.
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            Text("New Viewer")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            fields
            HStack(spacing: AppTheme.Space.m) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
                .accessibilityIdentifier("profile.save")
            }
        }
        .padding(AppTheme.Space.xl)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        #else
        NavigationStack {
            ScrollView {
                fields
                    .padding(AppTheme.Space.l)
                    .frame(maxWidth: AppTheme.readableWidth)
                    .frame(maxWidth: .infinity)
            }
            .background(Color.lobbyBackground(scheme))
            .navigationTitle("New Viewer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await save() }
                    }
                    .disabled(!canAdd)
                    .accessibilityIdentifier("profile.save")
                }
            }
        }
        #endif
    }

    /// The viewer as they will look, their name and their colour. The same on every platform.
    private var fields: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            VStack(spacing: AppTheme.Space.s) {
                ProfileAvatar(name: name, color: color, avatar: avatar, size: 88)
                if app.offersAvatars {
                    Button(avatar == nil ? "Choose a Picture…" : "Choose Another Picture…", systemImage: AppSymbol.picture) { isPicking = true }
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("profile.newPicture")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Space.s)
            .sheet(isPresented: $isPicking) { NewViewerAvatarSheet(name: name, color: color, avatar: $avatar) }

            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                Text("Name")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.lobbySecondary)
                TextField("Name", text: $name, prompt: Text("Who is watching?"))
                    .textFieldStyle(.plain)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .focused($nameIsFocused)
                    .onSubmit {
                        if canAdd { Task { await save() } }
                    }
                    .lobbyField()
                    .accessibilityIdentifier("profile.name")
            }

            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                Text("Colour")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.lobbySecondary)
                ColorSwatches(
                    colors: Self.colors, selection: Binding(get: { color }, set: { color = $0 ?? color }),
                    identifier: "profile.color")
            }

            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                Toggle("Is this a child?", isOn: $isKids)
                    .accessibilityIdentifier("profile.kids")
                Text("Then it becomes a kids viewer: large, simple screens with only what you allow. Choose that on the viewer's page, under Devices and Viewers.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(Color.lobbyFailure)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.failure")
            }
        }
        .onAppear { nameIsFocused = true }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.addProfile(name: name.trimmingCharacters(in: .whitespaces), color: color, avatar: avatar, kids: isKids ? KidsSettings() : nil)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
