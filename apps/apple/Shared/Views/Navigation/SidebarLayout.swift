// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// What the sidebar lists.
enum SidebarItem: Hashable, Sendable {
    case library
    case movies
    case series
    case downloads
    /// A category, by `CategoryShelf.id`.
    case category(String)
    /// The manager's tools. Only on a manager device.
    case manage
    /// The household's categories. Only on a manager device.
    case categories
    /// A place of the music.
    case music(MusicSection)
}

#if !os(tvOS)
/// Split navigation for a wide window: the iPad, and the Mac. Home, Movies, Series,
/// Downloads and the household's categories on the left.
struct SidebarLayout: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    @State private var showsGenres = false
    @State private var tint = PageTint()
    /// Which groups are folded away or show all; remembered on the device.
    @State private var fold = SidebarFold()
    /// A manager arranges categories by dragging them here too.
    @State private var arranging: CategoriesModel?

    var body: some View {
        @Bindable var app = app
        let query = app.searchText
        let shelves = app.shelves
        let categories = SidebarCategories(categories: shelves.categories, movies: shelves.movies, series: shelves.series)
        NavigationSplitView {
            List(selection: $app.sidebarSelection) {
                Section {
                    row(.library, "Home", AppSymbol.library)
                    row(.movies, "Movies", AppSymbol.movies)
                    row(.series, "Series", AppSymbol.series)
                }
                // The household's own parts of the library, each under its name. Only top-level
                // categories: those inside one are sections of its page.
                ForEach(shelves.groups) { group in
                    categorySection(group.categories, id: group.id) {
                        Label {
                            Text(group.name)
                        } icon: {
                            Image(systemName: AppSymbol.existing(app.look(ofGroup: group.id).symbol) ?? AppSymbol.group)
                                .foregroundStyle(.lobbySecondary)
                        }
                    }
                }
                if !categories.own.isEmpty {
                    categorySection(categories.own, id: Self.ownCategories) {
                        Text("Categories")
                    }
                }
                if !categories.genres.isEmpty {
                    genreSection(categories.genres)
                }
                if app.music.isAvailable {
                    Section {
                        ForEach(MusicSection.allCases, id: \.self) { section in
                            row(.music(section), section.title, section.symbol)
                        }
                    } header: {
                        Text("Music")
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                Section {
                    row(.downloads, "Downloads", AppSymbol.downloads)
                }
                if app.isManager {
                    Section {
                        row(.manage, "Devices and Viewers", AppSymbol.devices)
                        if app.isOwnerManager {
                            row(.categories, "Categories", AppSymbol.categories)
                        }
                    } header: {
                        Text("Household")
                            .foregroundStyle(.lobbySecondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(sidebarColor.ignoresSafeArea().animation(motion.moves ? .easeInOut(duration: 0.6) : nil, value: tint.palette))
            .navigationTitle("Lobby")
            #if os(macOS)
            // Wide enough for "Devices and Viewers" and the category names; it can be dragged
            // wider, and the window keeps where it was left.
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 400)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ProfileMenu()
                }
            }
        } detail: {
            NavigationStack(path: $app.libraryPath) {
                Group {
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty || app.isSearching {
                        SearchResultsView(query: $app.searchText)
                            .navigationTitle("Search")
                    } else {
                        // Another place in the sidebar is another page.
                        root.modifier(SectionChange(section: app.sidebarSelection ?? .library))
                    }
                }
                #if os(macOS)
                .returns(isInFront: app.libraryPath.isEmpty)
                #endif
                .lobbyDestinations()
            }
            .nowPlayingBar()
            .opensFromTiles()
            .musicMiniPlayer()
        }
        .environment(tint)
        .lobbySearch(text: $app.searchText, isSearching: $app.isSearching, prompt: app.music.isAvailable ? "Films, series and music" : "Films and series")
        .onChange(of: app.searchText) {
            // Typing a new search while a film is open shows the results, not the film.
            app.libraryPath = []
        }
        // Sidebar and content side by side, in portrait too, as the concept has them.
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .lobbyToolbar()
        #endif
        .onChange(of: app.sidebarSelection) {
            // Another section starts at its own top.
            app.libraryPath = []
            app.searchText = ""
        }
        .onAppear {
            fold = SidebarFold(folded: app.environment.settings.sidebarFoldedGroups, showsAll: app.environment.settings.sidebarShowsAllOfGroups)
        }
        .onChange(of: fold) { _, fold in
            app.environment.settings.sidebarFoldedGroups = fold.folded
            app.environment.settings.sidebarShowsAllOfGroups = fold.showsAll
        }
        .task(id: app.isManager ? app.categoryGroups.revision : -1) {
            // The setup to drag in, with its revision; read again whenever the categories changed.
            guard app.isManager else { arranging = nil; return }
            let model = arranging ?? CategoriesModel(app: app)
            arranging = model
            await model.load(suggestions: false)
            // Not being able to read it only means no dragging here; nothing to tell.
            if model.edit == nil { model.problem = nil }
        }
        .sheet(item: Binding(get: { arranging?.question }, set: { arranging?.question = $0 })) { question in
            if let arranging { KidsQuestionSheet(model: arranging, question: question) }
        }
        .alert(
            "That did not work",
            isPresented: Binding(get: { arranging?.problem != nil }, set: { if !$0 { arranging?.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(arranging?.problem ?? "")
        }
    }

    /// The id under which the main library's own categories fold.
    private static let ownCategories = "lobby.main"

    /// A part of the library: its heading folds it away, and a long one shows its first few and
    /// "More…".
    private func categorySection(
        _ shelves: [CategoryShelf], id: String, @ViewBuilder heading: () -> some View
    ) -> some View {
        let (shown, hidden) = fold.visible(shelves, ofGroup: id)
        let isFolded = fold.folded.contains(id)
        return Section {
            ForEach(shown) { category in
                categoryRow(category)
            }
            if hidden > 0 || fold.canShowLess(shelves.count, ofGroup: id) {
                Button {
                    withAnimation(motion.animation(.section)) { fold.toggleAll(id) }
                } label: {
                    Label(hidden > 0 ? "More… (\(hidden))" : "Show Less", systemImage: hidden > 0 ? "ellipsis" : "chevron.up")
                        .foregroundStyle(.lobbySecondary)
                }
                .buttonStyle(.lobbyRow)
                .accessibilityIdentifier("sidebar.more.\(id)")
            }
        } header: {
            Button {
                withAnimation(motion.animation(.section)) { fold.toggleFolded(id) }
            } label: {
                HStack(spacing: AppTheme.Space.xs) {
                    heading()
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.lobbySecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.lobbyRow)
            .accessibilityValue(isFolded ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("sidebar.group.\(id)")
        }
    }

    /// A category's row. On a manager's Mac it can be dragged to reorder and put inside another.
    @ViewBuilder
    private func categoryRow(_ category: CategoryShelf) -> some View {
        let label = row(.category(category.id), category.name, symbol(of: category))
        #if os(macOS)
        if let arranging, category.source == .folder {
            label.categoryDragging(category.categoryID, canHold: category.parentID == nil, model: arranging, isEnabled: !arranging.isBusy)
        } else {
            label
        }
        #else
        label
        #endif
    }

    @ViewBuilder
    private var root: some View {
        switch app.sidebarSelection ?? .library {
        case .library:
            LibraryHomeView()
        case .movies:
            BrowseView(scope: .movies, title: "Movies")
        case .series:
            BrowseView(scope: .series, title: "Series")
        case .downloads:
            DownloadsView()
        case .manage:
            // The row is only there for a manager. A device that lost the role while this was
            // open falls back to the library.
            if app.isManager {
                ManagerView(model: app.manager())
            } else {
                LibraryHomeView()
            }
        case .categories:
            if app.isOwnerManager {
                CategoriesView(app: app)
            } else {
                LibraryHomeView()
            }
        case .category(let id):
            CategoryPage(id: id)
        case .music(let section):
            MusicSectionView(section: section)
        }
    }

    /// The genres are many: one heading, opened when somebody wants them, and left that way.
    private func genreSection(_ genres: [CategoryShelf]) -> some View {
        Section {
            if showsGenres {
                ForEach(genres) { genre in
                    row(.category(genre.id), genre.name, AppSymbol.genre)
                }
            }
        } header: {
            Button {
                withAnimation(motion.animation(.section)) { showsGenres.toggle() }
            } label: {
                HStack(spacing: AppTheme.Space.xs) {
                    Text("Genres")
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showsGenres ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.lobbySecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.lobbyRow)
            .accessibilityValue(showsGenres ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("sidebar.genres")
        }
        .onAppear { showsGenres = app.environment.settings.sidebarShowsGenres }
        .onChange(of: showsGenres) { _, shows in app.environment.settings.sidebarShowsGenres = shows }
    }

    /// The sidebar's own colour, with a little of the page's beside it.
    private var sidebarColor: Color {
        tint.palette.flatMap { ArtworkColors($0, style: scheme == .dark ? .dark : .light) }
            .map { Color($0.sidebar) } ?? .lobbySidebar(scheme)
    }

    private static var selectionInset: CGFloat {
        #if os(macOS)
        10
        #else
        0
        #endif
    }

    private func symbol(of category: CategoryShelf) -> String {
        AppSymbol.existing(app.look(of: category).symbol) ?? AppSymbol.category
    }

    /// One quiet colour for every symbol. The chosen row is a tinted fill with the accent on its
    /// symbol, and the only colour in the sidebar. A category's own colour is on its cards.
    private func row(_ item: SidebarItem, _ title: String, _ symbol: String) -> some View {
        let isSelected = (app.sidebarSelection ?? .library) == item
        return Label {
            Text(title)
                .foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: symbol)
                .contentTransition(.interpolate)
                .foregroundStyle(isSelected ? Color.lobbyAccent(scheme) : Color.lobbySecondaryText(scheme))
                .accessibilityHidden(true)
        }
        #if os(macOS)
        .background(OwnSelection())
        #endif
        .tag(item)
        .listRowBackground(
            RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)
                .fill(isSelected ? Color.lobbySelection(scheme) : .clear)
                .padding(.horizontal, Self.selectionInset)
                .animation(motion.animation(.change), value: isSelected))
        .accessibilityIdentifier("sidebar.\(title)")
    }
}

/// The page of another section comes in over the window's colour.
private struct SectionChange: ViewModifier {
    let section: SidebarItem

    func body(content: Content) -> some View {
        content
            .modifier(FadesIn())
            .id(section)
    }
}

#if os(macOS)
/// Turns off the highlight AppKit draws behind a selected row (grey, or the full accent while
/// the list has the keyboard): the sidebar draws its own tinted fill. Selecting, with the mouse
/// or the arrow keys, stays the system's. Sits in a row, from where its list can be found.
private struct OwnSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            var view = superview
            while let here = view, !(here is NSTableView) { view = here.superview }
            (view as? NSTableView)?.selectionHighlightStyle = .none
        }
    }
}
#endif
#endif
