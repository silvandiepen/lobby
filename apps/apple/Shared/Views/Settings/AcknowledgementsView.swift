// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        LobbyForm {
            Section {
                Text(Acknowledgements.libjuice).textSelection(.enabled)
                Text(Acknowledgements.picohash).textSelection(.enabled)
                if let source = URL(string: "https://github.com/paullouisageneau/libjuice/tree/v1.7.5") {
                    Link("Source of libjuice 1.7.5", destination: source)
                }
                if let licence = URL(string: "https://www.mozilla.org/MPL/2.0/") {
                    Link("Mozilla Public License 2.0", destination: licence)
                }
            } header: {
                Label("libjuice", systemImage: AppSymbol.acknowledgements)
            } footer: {
                Text("Finds the way between this device and Lobby Server for the direct connection.")
            }
        }
        .navigationTitle("Acknowledgements")
    }
}
