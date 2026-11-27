// SPDX-License-Identifier: MPL-2.0
import Foundation

/// When a screen that everybody uses asks who is watching.
enum ViewerQuestion: String, CaseIterable, Hashable, Sendable {
    case eachTime, afterOneHour, afterFourHours, afterTwelveHours, never

    /// A look at something else and back is not another time.
    static let glance: TimeInterval = 10 * 60

    var name: String {
        switch self {
        case .eachTime: "Each time"
        case .afterOneHour: "After 1 hour"
        case .afterFourHours: "After 4 hours"
        case .afterTwelveHours: "After 12 hours"
        case .never: "Never"
        }
    }

    /// - Parameters:
    ///   - isLaunch: The app was started, instead of coming back to the front.
    ///   - lastUsed: When it was put away. nil: not known, which counts as long ago.
    func asks(isLaunch: Bool, lastUsed: Date?, now: Date) -> Bool {
        let away = lastUsed.map { now.timeIntervalSince($0) } ?? .infinity
        return switch self {
        case .eachTime: isLaunch || away >= Self.glance
        case .afterOneHour: away >= 3_600
        case .afterFourHours: away >= 4 * 3_600
        case .afterTwelveHours: away >= 12 * 3_600
        case .never: false
        }
    }
}
