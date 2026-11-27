// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import LobbyKit
import Observation

/// The Connect screen: find the server, check its name, then pair with a code a manager
/// approves, or claim a new server with its setup secret.
@MainActor
@Observable
final class ConnectModel {
    enum Step: Hashable, Sendable {
        /// Choosing one of the servers found on this network. Where Connect starts.
        case discover
        /// Typing the address: for a server that is not on this network (Tailscale), or when
        /// looking at the network is not allowed.
        case address
        /// The server answered. The family checks the name before pairing.
        case server(ServerInfo)
        /// A code is on screen and the app is waiting for a manager.
        case code(PairingRequest, ServerInfo)
        /// Typing the setup secret of a server nobody claimed yet.
        case setupSecret(ServerInfo)
        /// Away from home and from Tailscale: the code of a window a manager opened, and where to ask.
        case outside
        /// The six digits are on screen, and the manager compares them.
        case outsideDigits(DirectPairing.Waiting)
        /// Approved. The first connection is on its way, or has to be tried again.
        case outsideFinishing
    }

    /// What went wrong, in the viewer's terms. "Unreachable" is its own case because the answer
    /// to it is different: check the network, not the pairing.
    enum Problem: Hashable, Sendable {
        case invalidAddress
        case unreachable
        case codeExpired
        /// The server refused. Its own sentence is shown.
        case refused(String)
        /// This device cannot keep a credential, so pairing would be lost at once.
        case keychain(String)
        /// Pairing from outside went wrong, in plain words.
        case outside(String)

        var title: String {
            switch self {
            case .invalidAddress: "That is not a server address"
            case .unreachable: "Lobby Server cannot be reached"
            case .codeExpired: "The code expired"
            case .refused: "Lobby Server said no"
            case .keychain: "This device cannot store the pairing"
            case .outside: "Pairing from outside did not work"
            }
        }

        var explanation: String {
            switch self {
            case .invalidAddress:
                "Type the address of the Pi, like media.example.ts.net or 192.168.1.20."
            case .unreachable:
                "Check that this device is on the home network or connected to Tailscale, that the address is right, and that the Pi is on."
            case .codeExpired:
                "A code works for ten minutes. Ask for a new one."
            case .refused(let message), .outside(let message):
                message
            case .keychain(let message):
                "The Keychain, where Lobby keeps this device's credential, refused it: \(message) Nothing was changed on Lobby Server."
            }
        }
    }

    var addressText: String
    var setupSecretText = ""
    /// Where the introducer is.
    var introducerText: String
    /// The code so far: capitals, without hyphens.
    var outsideCode = "" {
        didSet {
            let clean = PairingCode.clean(outsideCode)
            if clean != outsideCode { outsideCode = clean }
        }
    }
    /// What a phone on this network reads to hand over the code. On the Apple TV.
    private(set) var handOverLink: String?
    /// Its household admin said yes; the server's owner is still to.
    private(set) var waitsForServerOwner = false
    /// A household's invitation that was opened or scanned: whose household and whose server
    /// this device is joining, to say so. nil for a window of one's own household.
    private(set) var joining: (household: String, server: String?)?
    private(set) var step: Step = .discover
    private(set) var isWorking = false
    /// The Lobby Servers in sight on this network.
    private(set) var discovered: [DiscoveredServer] = []
    /// The person did not allow the app to look at the local network.
    private(set) var discoveryIsDenied = false
    /// The found server that was tapped, while the app gets to it.
    private(set) var choosing: DiscoveredServer?
    private(set) var problem: Problem?

    private let app: AppModel
    private var address: URL?
    private var client: LobbyClient?
    private var pollTask: Task<Void, Never>?
    /// The server on screen was chosen from the found ones, not typed.
    private var cameFromTheNetwork = false

    init(app: AppModel) {
        self.app = app
        addressText = app.rememberedAddress
        introducerText = app.environment.settings.introducer ?? ""
    }

    var canContinue: Bool {
        !isWorking && !addressText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var canClaim: Bool {
        !isWorking && !setupSecretText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Servers on this network

    /// Runs for as long as the Connect screen is up: keeps the list of found servers.
    func watchNetwork() async {
        for await update in app.environment.discover() {
            discovered = update.servers
            discoveryIsDenied = update.isDenied
        }
    }

    /// The person tapped a found server: go straight on. For a server that has its manager
    /// that is the pairing code; a new server shows how it is set up first.
    func choose(_ server: DiscoveredServer) async {
        guard !isWorking else { return }
        problem = nil
        isWorking = true
        choosing = server
        defer {
            isWorking = false
            choosing = nil
        }
        do {
            let url = try await app.environment.addressOfDiscovered(server)
            let client = try LobbyClient(baseURL: url, session: app.environment.session)
            let info = try await client.serverInfo()
            if let announced = server.serverID, announced != info.id {
                // Something else answers where the announcement pointed.
                problem = .refused("Another server answered at the address of “\(server.name)”. Enter the address yourself.")
                return
            }
            if let other = app.account.otherAccountName(info.id) {
                problem = .refused(ServerAlreadyAdded(name: other).errorDescription ?? "")
                return
            }
            address = url
            self.client = client
            addressText = ServerAddress.display(url)
            app.rememberAddress(addressText)
            cameFromTheNetwork = true
            step = .server(info)
            if info.claimed {
                isWorking = false
                await requestCode()
            }
        } catch {
            problem = error is DiscoveryError
                ? .refused("“\(server.name)” could not be found any more. Is it still on?")
                : Self.problem(for: error)
        }
    }

    /// Type the address instead.
    func enterAddress() {
        problem = nil
        step = .address
    }

    // MARK: Steps

    /// `GET /v1/server`: is there a Lobby Server at this address, and what is it called?
    func findServer() async {
        problem = nil
        guard let url = ServerAddress.parse(addressText),
            let client = try? LobbyClient(baseURL: url, session: app.environment.session)
        else {
            problem = .invalidAddress
            return
        }
        // Pairing ends with a credential that is sent to this address from then on.
        guard AddressPolicy.mayCarryCredential(url) else {
            problem = .refused("That address is on the internet without encryption. Use its https address, or the one on your home network or Tailscale.")
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let server = try await client.serverInfo()
            if let other = app.account.otherAccountName(server.id) {
                problem = .refused(ServerAlreadyAdded(name: other).errorDescription ?? "")
                return
            }
            address = url
            self.client = client
            app.rememberAddress(addressText.trimmingCharacters(in: .whitespacesAndNewlines))
            cameFromTheNetwork = false
            step = .server(server)
        } catch {
            problem = Self.problem(for: error)
        }
    }

    /// Asks for a code and waits until a manager approves it.
    func requestCode() async {
        guard let client, let server = currentServer else { return }
        problem = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await checkCredentialStore()
            let request = try await client.requestPairing(
                deviceName: app.environment.device.name, platform: app.environment.device.platform)
            step = .code(request, server)
            waitForApproval(of: request, server: server, client: client)
        } catch {
            problem = Self.problem(for: error)
        }
    }

    /// For a server nobody claimed yet: show the field for the setup secret.
    func chooseSetupSecret() {
        guard case .server(let server) = step, !server.claimed, server.claim == .secret else { return }
        problem = nil
        step = .setupSecret(server)
    }

    /// A new server that asks for no secret: one tap, and this device is its manager.
    func setUp() async {
        guard case .server(let server) = step, !server.claimed, server.claim == .open else { return }
        await claim(server, secret: nil)
    }

    /// `POST /v1/pairing/claim` with the typed setup secret: this device becomes the server's
    /// first manager.
    func claim() async {
        guard case .setupSecret(let server) = step else { return }
        await claim(server, secret: setupSecretText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func claim(_ server: ServerInfo, secret: String?) async {
        guard let client, let address, !isWorking else { return }
        problem = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await checkCredentialStore()
            let grant = try await client.claim(
                setupSecret: secret, deviceName: app.environment.device.name, platform: app.environment.device.platform)
            setupSecretText = ""
            try await app.completePairing(address: address, server: server, grant: grant)
        } catch LobbyError.forbidden where secret == nil {
            // Another device was first, between looking and tapping.
            problem = .refused("Someone else has just set up this server. Ask them to approve this device.")
            if let info = try? await client.serverInfo() {
                step = .server(info)
            }
        } catch {
            problem = Self.problem(for: error)
        }
    }

    /// One step back: from the code or the secret to the server, from the server to the address.
    func back() {
        pollTask?.cancel()
        pollTask = nil
        problem = nil
        switch step {
        case .discover:
            break
        case .outsideFinishing:
            step = .discover
        case .outside:
            stopHandOver()
            step = .discover
        case .outsideDigits:
            endOutsidePairing()
            step = .outside
        case .address:
            step = .discover
        case .server:
            step = cameFromTheNetwork ? .discover : .address
        case .code(_, let server), .setupSecret(let server):
            setupSecretText = ""
            step = .server(server)
        }
    }

    /// Stops waiting, when the screen goes away.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        stopHandOver()
        endOutsidePairing()
    }

    // MARK: From outside

    private var pairing: DirectPairing?
    private var receiver: HandOverReceiver?

    /// Whether the app has a direct road at all.
    var offersOutside: Bool { app.environment.road != nil }

    var canPairOutside: Bool {
        !isWorking && PairingInvitation(introducer: introducerText, code: outsideCode) != nil
    }

    /// An earlier pairing that was approved and not finished, or a link that was opened.
    func resumeOutside() async {
        if await app.hasOutsidePairing() {
            step = .outsideFinishing
            await finishOutside()
        } else if let link = app.takeInvitation() {
            useInvitation(link)
        }
    }

    func chooseOutside() {
        problem = nil
        step = .outside
    }

    /// A scanned or opened `lobby://pair…`. It fills in, and a person goes on.
    func useInvitation(_ link: String) {
        if let invitation = PairingInvitation(link: link) {
            problem = nil
            introducerText = invitation.introducer.display
            outsideCode = invitation.code
            joining = invitation.household.map { ($0, invitation.server) }
            step = .outside
        } else if let household = HouseholdInvitation(link: link) {
            // Another household's invitation (`lobby://join…`): pairing from outside with its
            // code. Without an introducer in the link, the one known from before stays.
            problem = nil
            if let introducer = household.introducer { introducerText = introducer.display }
            outsideCode = household.code
            // The link names no household: nothing to say whose it is.
            joining = nil
            step = .outside
        } else {
            problem = .outside("That is not a code to pair Lobby with.")
        }
    }

    /// "You are joining The neighbours, on Alex's Lobby."
    var joiningText: String? {
        guard let joining else { return nil }
        if let server = joining.server { return "You are joining **\(joining.household)**, on \(server)." }
        return "You are joining **\(joining.household)**."
    }

    /// On the Apple TV, while its screen asks for the code: a phone on the same network can hand it over.
    func listenForHandOver() async {
        guard receiver == nil else { return }
        do {
            let (invitations, sink) = AsyncStream.makeStream(of: PairingInvitation.self)
            let receiver = try await HandOverReceiver.start { invitation in
                sink.yield(invitation)
                sink.finish()
            }
            self.receiver = receiver
            handOverLink = receiver.target.link
            for await invitation in invitations {
                introducerText = invitation.introducer.display
                outsideCode = invitation.code
                joining = invitation.household.map { ($0, invitation.server) }
                await pairOutside()
            }
        } catch {
            // Without a network there is nobody to hand anything over: typing is left.
        }
        stopHandOver()
    }

    func stopHandOver() {
        receiver?.stop()
        receiver = nil
        handOverLink = nil
    }

    private func endOutsidePairing() {
        guard let ended = pairing else { return }
        pairing = nil
        Task { await ended.close() }
    }

    /// Asks with the code, and shows the digits.
    func pairOutside() async {
        guard !isWorking, let invitation = PairingInvitation(introducer: introducerText, code: outsideCode) else { return }
        problem = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await checkCredentialStore()
            let pairing = DirectPairing(
                invitation: invitation, deviceName: app.environment.device.name,
                platform: app.environment.device.platform.rawValue)
            self.pairing = pairing
            let waiting = try await pairing.begin()
            guard self.pairing === pairing else { return await pairing.close() }
            app.environment.settings.introducer = invitation.introducer.url.absoluteString
            outsideCode = ""
            step = .outsideDigits(waiting)
            waitForManager(pairing, until: waiting.expiresAt)
        } catch {
            endOutsidePairing()
            problem = Self.outsideProblem(error)
        }
    }

    private func waitForManager(_ pairing: DirectPairing, until: Date) {
        pollTask?.cancel()
        waitsForServerOwner = false
        let waitsForOwner: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.waitsForServerOwner = true }
        }
        pollTask = Task { [weak self] in
            do {
                let grant = try DirectGrant(try await pairing.approval(until: until, waitingForAdmin: waitsForOwner))
                // Kept first: it is said only once.
                guard let self else { return }
                try await self.app.keepOutsidePairing(grant)
                await pairing.done()
                guard !Task.isCancelled else { return }
                self.pairing = nil
                self.step = .outsideFinishing
                await self.finishOutside()
            } catch is CancellationError {
                // The person went back.
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.endOutsidePairing()
                self.problem = Self.outsideProblem(error)
                self.step = .outside
            }
        }
    }

    /// The first connection over the direct road.
    func finishOutside() async {
        guard !isWorking else { return }
        problem = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.finishOutsidePairing()
        } catch is CancellationError {
            // The screen went away.
        } catch {
            problem = Self.outsideProblem(error)
        }
    }

    /// The person gives up on a pairing that was approved.
    func forgetOutside() async {
        await app.forgetOutsidePairing()
        problem = nil
        step = .discover
    }

    private static func outsideProblem(_ error: any Error) -> Problem {
        if let error = error as? CredentialStoreFailure { return .keychain(error.message) }
        if let error = error as? KeychainError { return .keychain(error.message) }
        return .outside(error.localizedDescription)
    }

    /// A credential is handed out exactly once, and a claim cannot be repeated. So before asking
    /// for either, make sure this device can keep one.
    private func checkCredentialStore() async throws {
        let probe = "lobby.keychain-check"
        do {
            try await app.environment.credentials.setToken(probe, forServer: probe)
            try await app.environment.credentials.removeToken(forServer: probe)
        } catch {
            throw CredentialStoreFailure(message: (error as? KeychainError)?.message ?? error.localizedDescription)
        }
    }

    private struct CredentialStoreFailure: Error {
        var message: String
    }

    private var currentServer: ServerInfo? {
        switch step {
        case .discover, .address, .outside, .outsideDigits, .outsideFinishing: nil
        case .server(let server), .code(_, let server), .setupSecret(let server): server
        }
    }

    private func waitForApproval(of request: PairingRequest, server: ServerInfo, client: LobbyClient) {
        pollTask?.cancel()
        let sleep = app.environment.sleep
        pollTask = Task { [weak self] in
            do {
                let grant = try await client.awaitPairingApproval(of: request, sleep: sleep)
                guard let self, let address = self.address, !Task.isCancelled else { return }
                try await self.app.completePairing(address: address, server: server, grant: grant)
            } catch is CancellationError {
                // The viewer went back.
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case LobbyError.gone = error {
                    self.problem = .codeExpired
                } else {
                    self.problem = Self.problem(for: error)
                }
                self.step = .server(server)
            }
        }
    }

    /// Waits for the approval that is being polled for. For tests.
    func waitUntilPaired() async {
        await pollTask?.value
    }

    private static func problem(for error: any Error) -> Problem {
        if let error = error as? CredentialStoreFailure {
            return .keychain(error.message)
        }
        if let error = error as? KeychainError {
            // Storing the real credential failed although the check before it passed.
            return .keychain(error.message)
        }
        guard let error = error as? LobbyError else {
            return .refused(error.localizedDescription)
        }
        if error.isUnreachable { return .unreachable }
        if case .invalidServerAddress = error { return .invalidAddress }
        if case .invalidResponse = error {
            return .refused("Something answered at this address, but it is not a Lobby Server.")
        }
        return .refused(error.localizedDescription)
    }
}

extension AppModel.ConnectNotice {
    var title: String {
        switch self {
        case .deviceRemoved: "This device was removed"
        case .credentialNotRecognised: "The server does not know this device"
        }
    }

    var explanation: String {
        switch self {
        case .deviceRemoved:
            "A manager removed this device from Lobby Server. The server is fine and can be reached: pair again to keep watching."
        case .credentialNotRecognised:
            "Lobby Server answered, but it has no record of this device. It may have been set up again. Pair to continue."
        }
    }
}
