// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A viewer's page for a manager: an ordinary viewer or a kids viewer, and what a kids viewer
/// may watch.
struct ViewerPageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var model: ViewerPageModel
    @State private var query = ""
    @State private var picking: Profile?

    init(app: AppModel, profileID: String) {
        _model = State(initialValue: ViewerPageModel(app: app, profileID: profileID))
    }

    var body: some View {
        Form {
            if let profile = model.profile {
                pictureSection(profile)
                if app.offersPlaybackPreferences {
                    playbackSection(profile)
                }
                Section {
                    NavigationLink(value: Route.viewerStats(profile.id)) {
                        Label(profile.kids != nil ? "What \(profile.name) Watches" : "Statistics", systemImage: "chart.bar.xaxis")
                    }
                    .accessibilityIdentifier("viewer.stats")
                } footer: {
                    if profile.kids != nil {
                        Text("Screen time each day, what, and when: evenings and weekends.")
                    }
                }
                kidsSection
                if app.offersSkipPreferences {
                    SkipSettingsSection(profileID: profile.id)
                }
                if model.kids != nil {
                    ForEach(model.groups) { group in
                        groupSection(group)
                    }
                    titlesSection
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.lobbyBackground(scheme))
        .overlay {
            if model.profile == nil {
                ContentUnavailableView("This viewer was removed", systemImage: AppSymbol.viewers)
            }
        }
        .sheet(item: $picking) { AvatarPickerSheet(app: app, profileID: $0.id) }
        .navigationTitle(model.profile?.name ?? "Viewer")
        .onChange(of: model.profile) { model.load() }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    private func pictureSection(_ profile: Profile) -> some View {
        Section {
            HStack(spacing: AppTheme.Space.l) {
                ProfileAvatar(profile: profile, size: 72)
                Text(profile.name)
                    .font(.title2.weight(.semibold))
            }
            .padding(.vertical, AppTheme.Space.xs)
            .accessibilityElement(children: .combine)
            if app.offersAvatars {
                Button("Choose a Picture…", systemImage: AppSymbol.picture) { picking = profile }
                    .accessibilityIdentifier("viewer.picture")
            }
        }
    }

    /// What happens at the end, for this viewer. For a kids viewer only here: the child's own
    /// device cannot change it.
    private func playbackSection(_ profile: Profile) -> some View {
        Section {
            NavigationLink {
                PlaybackSettingsView(profileID: profile.id)
            } label: {
                LabeledContent("Playback", value: PlaybackWords.summary(profile.playbackPreferences))
            }
            .accessibilityIdentifier("viewer.playback")
        } footer: {
            if profile.kids != nil {
                Text("Up Next, suggestions and \u{201C}Still watching?\u{201D} for this child. Asked after 2 episodes in a row unless you choose otherwise.")
            }
        }
    }

    private var kidsSection: some View {
        Section {
            if model.isWatchingHere {
                // Why the switch under it is off, and the way to turn it on.
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Label("You are watching as this viewer on this device", systemImage: AppSymbol.viewers)
                        .font(.headline)
                    Text("A kids viewer has only the kids screens, without this page. Choose another viewer here first.")
                        .font(.subheadline)
                        .foregroundStyle(.lobbySecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose Another Viewer") { app.chooseAnotherProfile() }
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("viewer.chooseAnother")
                }
                .accessibilityIdentifier("viewer.isWatching")
            }
            Toggle(isOn: Binding(get: { model.kids != nil }, set: { on in Task { await model.setIsKids(on) } })) {
                Label("Kids Viewer", systemImage: AppSymbol.kids)
            }
            .disabled(model.isWatchingHere)
            .accessibilityIdentifier("viewer.kids")
            if model.kids != nil {
                NavigationLink(value: Route.kidsPlan(model.profileID)) {
                    Label("When and What", systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("viewer.kidsPlan")
            }
        } footer: {
            if model.kids != nil {
                Text(model.summary)
                    .accessibilityIdentifier("viewer.summary")
            } else {
                Text("A kids viewer sees only what you allow, on large and simple screens. Leaving those asks for Face ID or the passcode.")
            }
        }
    }

    private func groupSection(_ group: CategoryGroup) -> some View {
        let allowsAll = model.allows(group: group.id)
        return Section {
            Toggle(isOn: Binding(get: { allowsAll }, set: { on in Task { await model.setAllows(on, group: group.id) } })) {
                Label("All of It", systemImage: AppSymbol.existing(group.icon) ?? AppSymbol.group)
            }
            .accessibilityIdentifier("viewer.group.\(group.name ?? "main")")
            ForEach(CategoryTree(group).rows) { row in
                categoryRow(row, in: group, allowsAll: allowsAll)
                    .padding(.leading, row.isInside ? AppTheme.Space.l : 0)
            }
        } header: {
            Text(group.name ?? "Library")
        }
    }

    @ViewBuilder
    private func categoryRow(_ row: CategoryTree.Row, in group: CategoryGroup, allowsAll: Bool) -> some View {
        let category = row.category
        let label = Label(category.name, systemImage: AppSymbol.existing(category.icon) ?? AppSymbol.category)
        if model.offersBlockingCategories {
            Picker(selection: Binding(
                get: { model.choice(forCategory: category.id) },
                set: { choice in Task { await model.set(choice, category: category.id) } })
            ) {
                Text(model.inherited(category: category.id, in: group)).tag(ViewerPageModel.CategoryChoice.asAbove)
                Text("Allowed").tag(ViewerPageModel.CategoryChoice.allowed)
                Text("Blocked").tag(ViewerPageModel.CategoryChoice.blocked)
            } label: {
                label
            }
            .accessibilityIdentifier("viewer.category.\(category.name)")
        } else {
            Toggle(isOn: Binding(
                get: { allowsAll || model.allows(category: category.id) },
                set: { on in Task { await model.setAllows(on, category: category.id) } })
            ) {
                label
            }
            .disabled(allowsAll)
            .accessibilityIdentifier("viewer.category.\(category.name)")
        }
    }

    private var titlesSection: some View {
        let rows = model.titles(query)
        return Section {
            TextField("Find", text: $query, prompt: Text("Find a film or series"))
                .accessibilityIdentifier("viewer.find")
            ForEach(rows.prefix(30)) { row in
                Picker(selection: Binding(get: { row.rule }, set: { rule in Task { await model.set(rule, for: row.id) } })) {
                    Text("By Category").tag(ViewerPageModel.Rule.byCategory)
                    Text("Allow").tag(ViewerPageModel.Rule.allowed)
                    Text("Block").tag(ViewerPageModel.Rule.blocked)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(row.item.title, systemImage: row.item.kind == .show ? AppSymbol.series : AppSymbol.movies)
                        Text(row.caption)
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("viewer.title.\(row.item.title)")
            }
        } header: {
            Text("Single Titles")
        } footer: {
            Text("The exceptions. A blocked title is never shown, whatever its category. A series counts for all its episodes.")
        }
    }
}
