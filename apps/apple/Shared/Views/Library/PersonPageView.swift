// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A person: what they are in that is in the library first, to play, then what else they made
/// (from TMDB, with its links). In kids mode only the titles the child may see.
struct PersonPageView: View {
    let personID: Int
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: SearchModel?
    @State private var page: PersonPage?
    @State private var failed = false
    @State private var shownOutside: OutsideTitle?
    private let metrics = TileMetrics()

    var body: some View {
        ScrollView {
            if let page {
                content(page)
            } else if failed {
                ContentUnavailableView(
                    "This person cannot be shown", systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Lobby Server could not be reached, or they are in nothing here."))
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, AppTheme.Space.xl)
            }
        }
        .background(Color.lobbyBackground(scheme))
        .navigationTitle(page?.person.name ?? "")
        .task(id: personID) {
            let model = model ?? app.makeSearchModel()
            self.model = model
            do {
                page = try await model.person(personID)
            } catch {
                failed = true
            }
        }
        .sheet(item: $shownOutside) { title in
            if let model { OutsideTitleSheet(title: title, model: model) }
        }
    }

    private func content(_ page: PersonPage) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            HStack(alignment: .top, spacing: AppTheme.Space.m) {
                SearchPicture(path: page.person.picture ?? page.outside?.picture, symbol: "person.fill", maxPixels: 400)
                    .frame(width: 110, height: 110)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(page.person.name).font(.largeTitle.weight(.bold))
                    if let known = page.outside?.knownFor { Text(known).foregroundStyle(.secondary) }
                    if let born = page.outside?.birthday {
                        Text(["Born \(born)", page.outside?.deathday.map { "died \($0)" }].compactMap { $0 }.joined(separator: ", "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let links = page.outside?.links {
                        HStack {
                            if let imdb = links.imdb { Link("Open on IMDb", destination: imdb) }
                            Link("Open on TMDB", destination: links.tmdb)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
            if let biography = page.outside?.biography {
                Text(biography).lineLimit(6).padding(.horizontal, TileMetrics.margin(sizeClass))
            }
            if !page.titles.isEmpty {
                Text("In Your Library").font(.title3.weight(.semibold)).padding(.horizontal, TileMetrics.margin(sizeClass))
                PosterGridBody(width: metrics.poster(sizeClass)) { width in
                    ForEach(page.titles) { found in
                        let item = app.item(found.item.id) ?? found.item
                        NavigationLink(value: Route.item(item.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                PosterTile(item: item, width: width)
                                if let role = found.roles.first {
                                    Text(role.character.map { "As \($0)" } ?? role.role.title)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.lobbyTile(opens: Route.item(item.id)))
                    }
                }
            }
            if let outside = page.outside, !outside.elsewhere.isEmpty {
                Shelf(title: "Not in Your Library") {
                    ForEach(outside.elsewhere) { one in
                        Button { shownOutside = one } label: { OutsideTile(title: one) }
                            .buttonStyle(.lobbyTile)
                    }
                }
            } else if let reason = page.outsideReason, !app.isKidsMode {
                Text(reason.message).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, TileMetrics.margin(sizeClass))
            }
        }
        .padding(.vertical, AppTheme.Space.l)
    }
}
