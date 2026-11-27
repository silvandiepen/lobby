// SPDX-License-Identifier: MPL-2.0
/// The grown-ups' code while it is typed with the remote.
struct CodeEntry: Hashable, Sendable {
    static let length = 4
    private(set) var digits = ""

    var isComplete: Bool { digits.count == Self.length }

    mutating func add(_ digit: Int) {
        guard !isComplete, (0...9).contains(digit) else { return }
        digits.append(String(digit))
    }

    mutating func delete() {
        if !digits.isEmpty { digits.removeLast() }
    }

    mutating func clear() {
        digits = ""
    }
}

extension KidsCodeCheck {
    /// What a grown-up reads on the TV when the code did not lead out.
    var explanation: String? {
        switch self {
        case .confirmed: nil
        case .wrong: "That is not the code."
        case .locked(let seconds):
            "Too many wrong codes. Try again in \(max(1, (seconds + 59) / 60)) min."
        case .noCode: Self.noCodeText
        case .bound: Self.boundText
        case .unreachable: "Lobby Server cannot be reached. Without it nobody can leave the kids pages."
        }
    }

    static let noCodeText =
        "Nobody chose a code yet. A manager does that in Lobby on an iPhone, iPad or Mac: Devices and Viewers, Code for Grown-ups. Then come back here."
    static let boundText =
        "A manager made this Apple TV a child's. Only a manager changes that, on an iPhone, iPad or Mac: Devices and Viewers, then this Apple TV."
}
