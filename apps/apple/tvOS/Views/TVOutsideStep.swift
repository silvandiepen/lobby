// SPDX-License-Identifier: MPL-2.0
import LobbyDirect
import LobbyKit
import SwiftUI

/// Pairing from outside on the TV. The easy way is a phone on the same network, which reads the QR
/// code; otherwise the remote picks the code's characters, and the address is typed (the system offers
/// a nearby iPhone's keyboard for that).
struct TVOutsideStep: View {
    @Bindable var model: ConnectModel
    @FocusState private var focus: Character?

    var body: some View {
        VStack(spacing: AppTheme.Space.xl) {
            Text("Pair from outside")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let joining = model.joiningText {
                // A household's invitation, handed over by a phone: whose this TV is joining.
                Text(.init(joining))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("connect.joining")
            }
            HStack(alignment: .top, spacing: TVMetrics.gap * 2) {
                phone
                typed
            }
            Button("Servers on This Network", systemImage: AppSymbol.onThisNetwork) { model.back() }
        }
        .task { await model.listenForHandOver() }
    }

    private var phone: some View {
        VStack(spacing: AppTheme.Space.l) {
            Text("With an iPhone or iPad").font(.headline)
            if let link = model.handOverLink {
                QRCodeView(text: link, size: 340, label: "Code for the Lobby app on a manager's iPhone or iPad")
            } else {
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(.secondary.opacity(0.2))
                    .frame(width: 340, height: 340)
                    .overlay { ProgressView() }
            }
            Text("A manager's, on this same network and on Tailscale: in Lobby open Devices and Viewers, Access From Outside, Pair a Device, and choose Send to an Apple TV.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 520)
        }
        .multilineTextAlignment(.center)
    }

    private var typed: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            Text("Or with the remote").font(.headline)
            Text("Ask a manager for a code and an address.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(shownCode)
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .accessibilityLabel("Code")
                .accessibilityValue(model.outsideCode.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("connect.outsideCode")
            keys
            TextField("Address, like introducer.example.com", text: $model.introducerText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 860)
                .accessibilityLabel("Address")
                .accessibilityIdentifier("connect.introducer")
            Button {
                Task { await model.pairOutside() }
            } label: {
                TVWorkingLabel(
                    title: model.isWorking ? "Asking…" : "Pair This Apple TV", symbol: AppSymbol.pair, isWorking: model.isWorking)
            }
            .disabled(!model.canPairOutside)
            .accessibilityIdentifier("connect.pairOutside")
        }
    }

    /// What is there, and a dot for each that is not.
    private var shownCode: String {
        let missing = PairingCode.length - model.outsideCode.count
        return PairingCode.grouped(model.outsideCode + String(repeating: "·", count: max(0, missing)))
    }

    /// The code's own 32 characters and nothing else: none of them can be read two ways.
    private var keys: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: AppTheme.Space.s) {
                    ForEach(PairingCode.alphabet[(row * 8)..<(row * 8 + 8)], id: \.self) { character in
                        Button(String(character)) { model.outsideCode.append(character) }
                            .font(.system(size: 30, weight: .medium, design: .monospaced))
                            .focused($focus, equals: character)
                            .disabled(model.outsideCode.count == PairingCode.length)
                            .accessibilityIdentifier("connect.key.\(character)")
                    }
                    if row == 0 {
                        Button { _ = model.outsideCode.popLast() } label: { Image(systemName: "delete.left") }
                            .disabled(model.outsideCode.isEmpty)
                            .accessibilityLabel("Delete")
                            .accessibilityIdentifier("connect.key.delete")
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .focusSection()
    }
}
