// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// The one-time setup of Lock to Lobby on this device: whether it is set up, and the button
/// that asks the system, which asks for Face ID or the passcode (docs/decisions.md, "Lock to Lobby").
struct KidsLockSetUp: View {
    let lock: KidsLock
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            LabeledContent("Lock to Lobby", value: lock.isAllowed ? "Set up" : "Not set up")
                .accessibilityIdentifier("kidsLock.status")
            if !lock.isAllowed {
                Button("Set Up Lock to Lobby…") { Task { await app.setUpKidsLock() } }
                    .disabled(lock.isSettingUp)
                    .accessibilityIdentifier("kidsLock.setUp")
                Text("Once on each iPhone or iPad a child uses. A grown-up allows Screen Time for Lobby with Face ID or the passcode. Then a manager can lock this device to Lobby in kids mode, from their own phone too.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
            if let problem = lock.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Color.lobbyFailure)
            }
        }
    }
}
