// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import Network

/// When the network comes back, so the app can send queued progress and fetch what changed.
enum Reachability {
    /// One element each time the device's network path changes, including the first look: which
    /// network it is, and whether it can be used.
    static func paths() -> AsyncStream<NetworkSignature> {
        AsyncStream { continuation in
            let task = Task {
                for await path in NWPathMonitor() {
                    continuation.yield(NetworkSignature(path))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
