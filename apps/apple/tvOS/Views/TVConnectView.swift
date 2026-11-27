// SPDX-License-Identifier: MPL-2.0
import LobbyDirect
import LobbyKit
import SwiftUI

/// Connect on the TV: choose a server found at home or type an address, then show a code that
/// a manager approves on their own device, wherever that is.
struct TVConnectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var model: ConnectModel

    init(app: AppModel) {
        _model = State(initialValue: ConnectModel(app: app))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Space.xl * 1.5) {
                CancelAddingServerButton()
                if let notice = app.connectNotice {
                    TVNotice(
                        symbol: "person.crop.circle.badge.xmark", tint: Color.lobbyFailure, title: notice.title,
                        text: notice.explanation)
                }
                step
                if let problem = model.problem {
                    TVNotice(
                        symbol: problem == .unreachable ? "wifi.slash" : "exclamationmark.triangle.fill",
                        tint: Color.lobbyWarning, title: problem.title, text: problem.explanation)
                    .accessibilityIdentifier("connect.problem")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Space.xl * 2)
        }
        .scrollClipDisabled()
        .task { await model.watchNetwork() }
        .task { await model.resumeOutside() }
        .onDisappear { model.cancel() }
        // Menu goes a step back; on the first screen it leaves the app, as it does everywhere.
        .onExitCommand(perform: model.step == .discover ? nil : { model.back() })
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .discover: discover
        case .address: address
        case .server(let server): serverStep(server)
        case .code(let request, let server): code(request, server)
        // A TV is never a server's first manager: see `serverStep`.
        case .setupSecret(let server): serverStep(server)
        case .outside: TVOutsideStep(model: model)
        case .outsideDigits(let waiting): digits(waiting)
        case .outsideFinishing: finishing
        }
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(spacing: AppTheme.Space.m) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: TVMetrics.readable)
    }

    private var discover: some View {
        VStack(spacing: AppTheme.Space.xl * 1.5) {
            heading("Choose your Lobby Server", "At home it is found by itself. Away from home, enter its address.")
            if !model.discovered.isEmpty {
                VStack(spacing: AppTheme.Space.l) {
                    ForEach(model.discovered) { server in
                        Button {
                            guard !model.isWorking else { return }
                            Task { await model.choose(server) }
                        } label: {
                            TVWorkingLabel(title: server.name, symbol: AppSymbol.server, isWorking: model.choosing == server)
                                .frame(minWidth: 560)
                        }
                        .accessibilityIdentifier("connect.found.\(server.name)")
                    }
                }
            } else if model.discoveryIsDenied {
                TVNotice(
                    symbol: "network.slash", tint: Color.lobbyWarning, title: "Lobby may not look at this network",
                    text: "Allow it in Settings, under General, Privacy & Security, Local Network. Or enter the server's address.")
            } else {
                WaitedReader { waited in
                    if Patience.discoveryFoundNothing(waited: waited) {
                        TVNotice(
                            symbol: "wifi", tint: .secondary, title: "No Lobby Server on this network",
                            text: "At home, check that the Pi is on and that this Apple TV is on the same network. Away from home, connect Tailscale and enter the server's address. One that appears later is still shown here.")
                    } else {
                        ProgressView("Looking for Lobby Servers…")
                    }
                }
            }
            HStack(spacing: TVMetrics.gap) {
                Button("Enter Address", systemImage: AppSymbol.enterAddress) { model.enterAddress() }
                    .accessibilityIdentifier("connect.enterAddress")
                if model.offersOutside {
                    Button("Pair From Outside", systemImage: AppSymbol.outside) { model.chooseOutside() }
                        .accessibilityIdentifier("connect.outside")
                }
            }
        }
    }

    private var address: some View {
        VStack(spacing: AppTheme.Space.xl) {
            heading("Enter the address", "The name or number of the server on your home network or on Tailscale.")
            TextField("media.example.ts.net", text: $model.addressText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 900)
                .onSubmit { Task { await model.findServer() } }
                .accessibilityLabel("Server address")
                .accessibilityIdentifier("connect.address")
            Button {
                guard model.canContinue else { return }
                Task { await model.findServer() }
            } label: {
                TVWorkingLabel(
                    title: model.isWorking ? "Connecting…" : "Continue", symbol: "arrow.forward", isWorking: model.isWorking)
            }
            .accessibilityIdentifier("connect.continue")
            Button("Servers on This Network", systemImage: AppSymbol.onThisNetwork) { model.back() }
        }
    }

    private func serverStep(_ server: ServerInfo) -> some View {
        VStack(spacing: AppTheme.Space.xl) {
            heading(server.name, "\(model.addressText)\nLobby Server \(server.version)")
            if server.claimed {
                Button {
                    guard !model.isWorking else { return }
                    Task { await model.requestCode() }
                } label: {
                    TVWorkingLabel(
                        title: model.problem == .codeExpired ? "Show a New Code" : "Pair This Apple TV",
                        symbol: AppSymbol.pair, isWorking: model.isWorking)
                }
                .accessibilityIdentifier("connect.pair")
            } else {
                TVNotice(
                    symbol: AppSymbol.setUp, tint: NavigationTint.manage, title: "This server is new",
                    text: "Set it up with Lobby on an iPhone, iPad or Mac first. Then come back here and pair this Apple TV.")
                Button("Look Again", systemImage: AppSymbol.refresh) {
                    guard !model.isWorking else { return }
                    Task { await model.findServer() }
                }
            }
            Button("Choose Another Server", systemImage: AppSymbol.back) { model.back() }
        }
    }

    private func digits(_ waiting: DirectPairing.Waiting) -> some View {
        VStack(spacing: AppTheme.Space.xl) {
            heading(
                "Compare these digits",
                "The manager's screen, under Access From Outside, must show the same six. If it does not, the manager refuses.")
            Text(PairingCodeText.grouped(waiting.comparison))
                .font(.system(size: 200, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.vertical, AppTheme.Space.xl)
                .padding(.horizontal, AppTheme.Space.xl * 2)
                .lobbyPanel(cornerRadius: 32)
                .accessibilityLabel("Digits to compare")
                .accessibilityValue(waiting.comparison.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("connect.comparison")
            Text(model.waitsForServerOwner
                ? "Waiting for the server owner to approve."
                : "Waiting for the manager, until \(waiting.expiresAt, format: .dateTime.hour().minute()).")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { model.back() }
        }
    }

    private var finishing: some View {
        VStack(spacing: AppTheme.Space.xl) {
            heading("Approved", "Lobby connects to the server for the first time.")
            Button {
                Task { await model.finishOutside() }
            } label: {
                TVWorkingLabel(title: model.isWorking ? "Connecting…" : "Connect", symbol: "arrow.forward", isWorking: model.isWorking)
            }
            .disabled(model.isWorking)
            Button("Start Over") { Task { await model.forgetOutside() } }
                .disabled(model.isWorking)
        }
    }

    private func code(_ request: PairingRequest, _ server: ServerInfo) -> some View {
        VStack(spacing: AppTheme.Space.xl) {
            heading(
                "Ask a manager to approve this code",
                "In Lobby on an iPhone, iPad or Mac that manages \(server.name): Devices and Viewers. It does not have to be in this house.")
            Text(PairingCodeText.grouped(request.code))
                .font(.system(size: 200, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.vertical, AppTheme.Space.xl)
                .padding(.horizontal, AppTheme.Space.xl * 2)
                .lobbyPanel(cornerRadius: 32)
                .accessibilityLabel("Pairing code")
                .accessibilityValue(request.code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("connect.code")
            Text("Waiting for approval. The code works until \(request.expiresAt, format: .dateTime.hour().minute()).")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { model.back() }
        }
    }
}
