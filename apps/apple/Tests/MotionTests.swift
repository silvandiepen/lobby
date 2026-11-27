// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Testing

@testable import Lobby

/// What moves, and what does not for who asked for that.
@Suite struct MotionTests {
    private let full = Motion(reduceMotion: false)
    private let kids = Motion(reduceMotion: false, isPlayful: true)
    private let light = Motion(reduceMotion: false, lowPower: true)

    private static let still = [
        Motion(reduceMotion: true), Motion(reduceMotion: true, isPlayful: true),
        // Reduce Motion wins over Low Power Mode.
        Motion(reduceMotion: true, lowPower: true), Motion(reduceMotion: true, lowPower: true, isPlayful: true),
    ]

    @Test(arguments: still)
    func reduceMotionOnlyFades(motion: Motion) {
        #expect(motion.level == .still)
        for role in Motion.Role.allCases {
            guard case .ease(let duration) = motion.curve(role) else {
                Issue.record("\(role) is a spring with Reduce Motion.")
                continue
            }
            #expect(duration <= 0.2)
        }
        // Nothing changes place or size.
        #expect(motion.pressScale == 1)
        #expect(motion.tilePressScale == 1)
        #expect(motion.hoverScale == 1)
        #expect(motion.openScale == 1)
        #expect(motion.returnScale == 1)
        #expect(motion.edgeScale == 1)
        #expect(motion.arrivalOffset == 0)
        #expect(motion.edgeOffset == 0)
        #expect(motion.parallax == 0)
        #expect(!motion.stretches)
        #expect(!motion.zooms)
        #expect(!motion.animatesSymbols)
        #expect((0..<20).allSatisfy { motion.arrivalDelay($0) == 0 })
        // A press is still seen.
        #expect(motion.pressDim > full.pressDim)
    }

    @Test func lowPowerDropsWhatScrollsAndWhatCoversTheScreen() {
        #expect(light.level == .light)
        #expect(light.edgeScale == 1)
        #expect(light.edgeOpacity == 1)
        #expect(light.edgeOffset == 0)
        #expect(light.parallax == 0)
        #expect(!light.zooms)
        #expect(light.arrivalDelay(5) == 0)
        // Buttons feel the same.
        #expect(light.pressScale == full.pressScale)
        #expect(light.curve(.release) == full.curve(.release))
    }

    @Test func aPressIsAtOnceAndItsReleaseIsASpring() {
        for motion in [full, kids, light] {
            #expect(motion.curve(.press) == .ease(duration: 0.08))
            guard case .spring = motion.curve(.release) else {
                Issue.record("A release is not a spring.")
                continue
            }
            #expect(motion.pressScale < 1)
        }
    }

    @Test func theKidsScreensMoveSofterAndDoNotBounceAbout() {
        #expect(kids.pressScale == full.pressScale)
        #expect(kids.edgeScale == full.edgeScale)
        #expect(kids.arrivalOffset > full.arrivalOffset)
        for role in Motion.Role.allCases {
            guard case .spring(let response, let damping) = kids.curve(role), case .spring(let usual, _) = full.curve(role) else { continue }
            #expect(damping >= 0.62, "\(role)")
            #expect(response >= usual, "\(role)")
        }
    }

    @Test func aPageHasArrivedWithinAThirdOfASecond() {
        #expect(full.arrivalDelay(0) == 0)
        #expect(full.arrivalDelay(1) > 0)
        #expect((0..<1_000).allSatisfy { full.arrivalDelay($0) <= 0.3 })
        #expect(full.arrivalDelay(-1) == 0)
    }

    @Test func aDownloadIsFeltWhenItStartsAndWhenItIsThere() {
        #if !os(tvOS)
        #expect(DownloadButton.feedback(from: .downloading, to: .downloaded) == .success)
        #expect(DownloadButton.feedback(from: .notDownloaded, to: .queued) == .impact(weight: .light))
        #expect(DownloadButton.feedback(from: .queued, to: .downloading) == nil)
        #expect(DownloadButton.feedback(from: .downloading, to: .paused) == nil)
        #endif
    }

    @MainActor
    @Test func aPageComesFromTheTileThatWasPressedLast() {
        let origins = OpenOrigins(), first = UUID(), second = UUID()
        #expect(origins.source(of: AnyHashable(Route.item("a"))) == nil)
        origins.opened(AnyHashable(Route.item("a")), from: first)
        origins.opened(AnyHashable(Route.item("a")), from: second)
        #expect(origins.source(of: AnyHashable(Route.item("a"))) == second)
        #expect(origins.source(of: AnyHashable(Route.category("a"))) == nil)
    }
}
