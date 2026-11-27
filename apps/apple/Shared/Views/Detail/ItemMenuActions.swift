// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Start from Beginning, and Mark as Watched or Unwatched, for the active viewer. In a film's
/// More menu and in an episode's context menu.
struct ItemMenuActions: View {
    let itemID: String
    let watch: WatchState
    let action: PlayAction

    @Environment(AppModel.self) private var app

    var body: some View {
        if let request = action.fromBeginning {
            Button("Start from Beginning", systemImage: AppSymbol.startOver) {
                app.play(request)
            }
        }
        if watch != .watched {
            Button("Mark as Watched", systemImage: AppSymbol.markWatched) {
                Task { await app.markWatched(itemID: itemID) }
            }
        }
        if watch != .unwatched {
            Button("Mark as Unwatched", systemImage: AppSymbol.markUnwatched) {
                Task { await app.markUnwatched(itemID: itemID) }
            }
        }
    }
}
