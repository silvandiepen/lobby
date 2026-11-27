// SPDX-License-Identifier: MPL-2.0
import LocalAuthentication

/// Asks whoever holds the device to prove they are the one it belongs to: Face ID, Touch ID
/// or the passcode.
enum GrownUpGate {
    static func ask() async -> GrownUpCheck {
        let context = LAContext()
        var problem: NSError?
        // Not biometrics alone: a grown-up whose face is not on the device knows the passcode.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            return check(for: problem)
        }
        do {
            let passed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "Lobby asks for a grown-up before it leaves the kids screens.")
            return passed ? .confirmed : .refused
        } catch {
            return check(for: error as NSError)
        }
    }

    /// Anything that is not a pass keeps the child where it is. Only a missing passcode is
    /// worth explaining: the rest, the person saw happen.
    static func check(for error: NSError?) -> GrownUpCheck {
        error?.domain == LAError.errorDomain && error?.code == LAError.passcodeNotSet.rawValue ? .unavailable : .refused
    }
}
