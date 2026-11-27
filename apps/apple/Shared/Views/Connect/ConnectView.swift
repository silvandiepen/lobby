// SPDX-License-Identifier: MPL-2.0
import LobbyDirect
import LobbyKit
import SwiftUI

/// Connect: find the server, check its name, pair.
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var model: ConnectModel
    @Environment(\.motion) private var motion
    @FocusState private var focus: Field?

    private enum Field { case address, secret, introducer, code }
    @State private var isScanning = false

    init(app: AppModel) {
        _model = State(initialValue: ConnectModel(app: app))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Space.xl) {
                CancelAddingServerButton()
                    .buttonStyle(QuietButtonStyle())
                    .frame(maxWidth: 320, alignment: .leading)
                masthead
                if let notice = app.connectNotice {
                    NoticeView(
                        symbol: "person.crop.circle.badge.xmark", tint: Color.lobbyFailure,
                        title: notice.title, text: notice.explanation
                    )
                    .accessibilityIdentifier("connect.notice")
                }
                step
                    .transition(motion.moves
                        ? .asymmetric(insertion: .offset(y: motion.arrivalOffset).combined(with: .opacity), removal: .opacity) : .opacity)
                if let problem = model.problem {
                    NoticeView(
                        symbol: problem == .unreachable ? "wifi.slash" : "exclamationmark.triangle.fill",
                        tint: Color.lobbyWarning, title: problem.title, text: problem.explanation
                    )
                    .accessibilityIdentifier("connect.problem")
                }
            }
            .frame(maxWidth: AppTheme.readableWidth, alignment: .leading)
            .padding(AppTheme.Space.l)
            .frame(maxWidth: .infinity)
            .animation(motion.animation(.section), value: model.step)
            .animation(motion.animation(.list), value: model.problem)
            .animation(motion.animation(.list), value: model.discovered)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.lobbyBackground(scheme))
        .task { await model.watchNetwork() }
        .task(id: app.invitation) { await model.resumeOutside() }
        .onDisappear { model.cancel() }
        #if os(iOS)
        .sheet(isPresented: $isScanning) {
            QRScannerSheet(title: "Scan the Manager's Code") { scanned in
                isScanning = false
                model.useInvitation(scanned)
            }
        }
        #endif
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.lobbyAccent(scheme))
                .accessibilityHidden(true)
            Text("Lobby")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Your household's films and series.")
                .font(.title3)
                .foregroundStyle(.lobbySecondary)
        }
        .padding(.top, AppTheme.Space.xl)
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .discover:
            discoverStep
        case .address:
            addressStep
        case .server(let server):
            serverStep(server)
        case .code(let request, let server):
            codeStep(request, server)
        case .setupSecret(let server):
            secretStep(server)
        case .outside:
            outsideStep
        case .outsideDigits(let waiting):
            digitsStep(waiting)
        case .outsideFinishing:
            finishingStep
        }
    }

    // MARK: Servers on this network

    private var discoverStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(title: "Choose your Lobby Server", text: "These are on this network.")

            if model.discovered.isEmpty {
                if model.discoveryIsDenied {
                    NoticeView(
                        symbol: "network.slash", tint: Color.lobbyWarning,
                        title: "Lobby may not look at this network",
                        text: "Allow it in Settings, under Privacy & Security, Local Network. Or enter the server's address below.")
                    .accessibilityIdentifier("connect.discoveryDenied")
                } else {
                    HStack(spacing: AppTheme.Space.m) {
                        ProgressView()
                        Text("Looking for Lobby Servers…")
                            .foregroundStyle(.lobbySecondary)
                    }
                    .padding(AppTheme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lobbyPanel()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("connect.looking")
                    Text("If you are asked whether Lobby may find devices on your local network, choose Allow: that is how it finds the server.")
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            } else {
                VStack(spacing: AppTheme.Space.s) {
                    ForEach(model.discovered) { server in
                        Button {
                            Task { await model.choose(server) }
                        } label: {
                            HStack(spacing: AppTheme.Space.l) {
                                Image(systemName: AppSymbol.server)
                                    .font(.title2)
                                    .foregroundStyle(NavigationTint.series)
                                // The announcement's `v` is not the version people know the
                                // server by; the next screen shows that one.
                                Text(server.name)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: AppTheme.Space.m)
                                if model.choosing == server {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.forward")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.lobbySecondary)
                                }
                            }
                            .padding(AppTheme.Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lobbyPanel()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.lobbyRow)
                        .disabled(model.isWorking)
                        .accessibilityLabel(server.name)
                        .accessibilityHint("Connects to this Lobby Server")
                        .accessibilityIdentifier("connect.found.\(server.name)")
                    }
                }
            }

            Button("Enter Address", systemImage: AppSymbol.enterAddress) { model.enterAddress() }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("connect.enterAddress")
            Text("Away from home, over Tailscale, the server is not found by itself: enter its address.")
                .font(.footnote)
                .foregroundStyle(.lobbySecondary)
            if model.offersOutside {
                Button("Pair From Outside", systemImage: AppSymbol.outside) { model.chooseOutside() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("connect.outside")
                Text("Away from home without Tailscale: with a code that a manager of the server gives you.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
    }

    // MARK: Address

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(title: "Find your Lobby Server", text: "Type the address of the Pi it runs on.")
            TextField("media.example.ts.net", text: $model.addressText)
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($focus, equals: .address)
                .onSubmit { Task { await model.findServer() } }
                .lobbyField()
                .accessibilityLabel("Server address")
                .accessibilityIdentifier("connect.address")
            Button {
                focus = nil
                Task { await model.findServer() }
            } label: {
                WorkingLabel(title: "Continue")
            }
            .buttonStyle(ProminentButtonStyle())
            .busy(model.isWorking)
            .disabled(!model.canContinue)
            .accessibilityIdentifier("connect.continue")
            Button("Servers on This Network", systemImage: AppSymbol.onThisNetwork) { model.back() }
                .font(.subheadline)
                .accessibilityIdentifier("connect.backToFound")
        }
    }

    // MARK: Server

    private func serverStep(_ server: ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(
                title: "Is this your server?",
                text: server.claimed ? "Check the name before you pair." : "Check the name before you set it up.")
            ServerCard(server: server, address: model.addressText)

            if server.claimed {
                Button {
                    Task { await model.requestCode() }
                } label: {
                    WorkingLabel(title: "Pair This Device", symbol: AppSymbol.pair)
                }
                .buttonStyle(ProminentButtonStyle())
                .busy(model.isWorking)
                .disabled(model.isWorking)
                .accessibilityIdentifier("connect.pair")
            } else if server.claim == .open {
                // Nobody manages this server yet, so nobody can approve a code: the first
                // device sets it up, with one tap.
                Button {
                    Task { await model.setUp() }
                } label: {
                    WorkingLabel(title: "Set Up This Server", symbol: AppSymbol.setUp)
                }
                .buttonStyle(ProminentButtonStyle())
                .busy(model.isWorking)
                .disabled(model.isWorking)
                .accessibilityIdentifier("connect.setUp")
                Text("This server is new. This device becomes its manager: it adds the viewers and approves the other devices.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            } else {
                Button("Enter the Setup Secret", systemImage: AppSymbol.secret) { model.chooseSetupSecret() }
                    .buttonStyle(ProminentButtonStyle())
                    .accessibilityIdentifier("connect.useSecret")
                Text("This server is new and asks for its setup secret, which Lobby Server printed when it first started. The device that enters it becomes the manager.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }

            Button("Choose Another Server", systemImage: AppSymbol.back) { model.back() }
                .font(.subheadline)
                .accessibilityIdentifier("connect.back")
        }
    }

    // MARK: Code

    private func codeStep(_ request: PairingRequest, _ server: ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(
                title: "Ask a manager to approve this code",
                text: "On a device that manages \(server.name), choose Approve a Device and type it in.")
            Text(request.code)
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .tracking(6)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Space.xl)
                .lobbyPanel()
                .accessibilityLabel("Pairing code")
                .accessibilityValue(request.code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("connect.code")
                .textSelection(.enabled)
            CopyCodeButton(code: request.code)
            HStack(spacing: AppTheme.Space.m) {
                ProgressView()
                Text("Waiting for approval. The code works until \(request.expiresAt, format: .dateTime.hour().minute()).")
                    .font(.subheadline)
                    .foregroundStyle(.lobbySecondary)
            }
            Button("Cancel") { model.back() }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("connect.cancel")
        }
    }

    // MARK: From outside

    private var outsideStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(
                title: model.joiningText == nil ? "Pair from outside" : "Join a household",
                text: model.joiningText.map { "\($0) The library is theirs to share; this device will manage your own household's devices and viewers." }
                    ?? "A manager opens **Access From Outside** in Lobby, at home or over Tailscale, and gives you a code and an address. An invitation to a household is entered the same way.")
            #if os(iOS)
            Button("Scan the Manager's Code", systemImage: AppSymbol.scan) { isScanning = true }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("connect.scan")
            #endif
            TextField("XXXX-XXXX-XXXX-XXXX", text: Binding(
                get: { PairingCode.grouped(model.outsideCode) }, set: { model.outsideCode = $0 }))
                .font(.system(.title3, design: .monospaced))
                #if !os(macOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .code)
                .lobbyField()
                .accessibilityLabel("Code")
                .accessibilityIdentifier("connect.outsideCode")
            TextField("introducer.example.com", text: $model.introducerText)
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .focused($focus, equals: .introducer)
                .lobbyField()
                .accessibilityLabel("Address")
                .accessibilityIdentifier("connect.introducer")
            Button {
                focus = nil
                Task { await model.pairOutside() }
            } label: {
                WorkingLabel(title: "Pair This Device", symbol: AppSymbol.pair)
            }
            .buttonStyle(ProminentButtonStyle())
            .busy(model.isWorking)
            .disabled(!model.canPairOutside)
            .accessibilityIdentifier("connect.pairOutside")
            Button("Servers on This Network", systemImage: AppSymbol.onThisNetwork) { model.back() }
                .font(.subheadline)
        }
    }

    private func digitsStep(_ waiting: DirectPairing.Waiting) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(
                title: "Compare these digits",
                text: "The manager's screen must show the same six. If it does not, the manager refuses.")
            Text(ManagerModel.spaced(waiting.comparison))
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Space.xl)
                .lobbyPanel()
                .accessibilityLabel("Digits to compare")
                .accessibilityValue(waiting.comparison.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("connect.comparison")
            HStack(spacing: AppTheme.Space.m) {
                ProgressView()
                Text(model.waitsForServerOwner
                    ? "Waiting for the server owner to approve."
                    : "Waiting for the manager, until \(waiting.expiresAt, format: .dateTime.hour().minute()).")
                    .font(.subheadline)
                    .foregroundStyle(.lobbySecondary)
            }
            Button("Cancel") { model.back() }
                .buttonStyle(QuietButtonStyle())
        }
    }

    private var finishingStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(title: "Approved", text: "Lobby connects to the server for the first time.")
            Button {
                Task { await model.finishOutside() }
            } label: {
                WorkingLabel(title: "Connect")
            }
            .buttonStyle(ProminentButtonStyle())
            .busy(model.isWorking)
            .disabled(model.isWorking)
            .accessibilityIdentifier("connect.finishOutside")
            Button("Start Over") { Task { await model.forgetOutside() } }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.isWorking)
        }
    }

    // MARK: Setup secret

    private func secretStep(_ server: ServerInfo) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            StepHeading(
                title: "Claim \(server.name)",
                text: "Type the setup secret. On the Pi, `lobby setup-secret` prints it. This device becomes the manager.")
            SecureField("Setup secret", text: $model.setupSecretText)
                .textContentType(.password)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.go)
                .focused($focus, equals: .secret)
                .onSubmit { Task { await model.claim() } }
                .lobbyField()
                .accessibilityIdentifier("connect.secret")
            Button {
                focus = nil
                Task { await model.claim() }
            } label: {
                WorkingLabel(title: "Claim This Server")
            }
            .buttonStyle(ProminentButtonStyle())
            .busy(model.isWorking)
            .disabled(!model.canClaim)
            .accessibilityIdentifier("connect.claim")
            Button("Back") { model.back() }
                .buttonStyle(QuietButtonStyle())
        }
        .onAppear { focus = .secret }
    }
}

private struct StepHeading: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(.init(text))
                .font(.body)
                .foregroundStyle(.lobbySecondary)
        }
    }
}

/// The server that answered: its name large, so the family can check it.
private struct ServerCard: View {
    let server: ServerInfo
    let address: String

    var body: some View {
        HStack(spacing: AppTheme.Space.l) {
            Image(systemName: "server.rack")
                .font(.title)
                .foregroundStyle(NavigationTint.series)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text(server.name)
                    .font(.title2.weight(.semibold))
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.lobbySecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Lobby Server \(server.version)")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
        .padding(AppTheme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lobbyPanel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connect.server")
    }
}

/// A message with a symbol: what happened and what to do about it.
struct NoticeView: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.lobbySecondary)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .padding(AppTheme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lobbyPanel()
        .accessibilityElement(children: .combine)
    }
}

/// A button label that shows a spinner while its action runs.
struct WorkingLabel: View {
    let title: String
    /// What the button means. The button's style puts a spinner in the place of it all.
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: AppTheme.Space.s) {
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
    }
}

extension View {
    /// A text field on the near-black background: a filled, rounded surface with no border.
    func lobbyField() -> some View {
        modifier(FieldBackground())
    }
}

private struct FieldBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.vertical, AppTheme.Space.m)
            .padding(.horizontal, AppTheme.Space.l)
            .background(Color.lobbySurface(scheme), in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
    }
}
