// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import Lobby

/// The app's icon follows kids mode: which icon is wanted, nothing asked when it shows already,
/// and nothing for a moment's kids mode.
@MainActor
@Suite struct KidsIconTests {
    /// Shows what it is told, and counts how often it was asked.
    final class FakeSurface: AppIconSurface {
        var current = AppIconChoice.primary
        var canSwitch = true
        var shown: [AppIconChoice] = []

        func show(_ icon: AppIconChoice) async {
            shown.append(icon)
            current = icon
        }
    }

    private func state(kids: Bool, on: Bool = true, active: Bool = true, playing: Bool = false) -> KidsIconSwitcher.State {
        KidsIconSwitcher.State(isKidsMode: kids, isOn: on, isActive: active, isPlaying: playing)
    }

    @Test func wantsTheKidsIconOnlyInKidsModeWithTheSettingOn() {
        #expect(KidsIconRule.wanted(isKidsMode: true, isOn: true) == .kids)
        #expect(KidsIconRule.wanted(isKidsMode: true, isOn: false) == .primary)
        #expect(KidsIconRule.wanted(isKidsMode: false, isOn: true) == .primary)
        #expect(KidsIconRule.wanted(isKidsMode: false, isOn: false) == .primary)
    }

    @Test func namesTheAlternateIconAndReadsItBack() {
        #expect(KidsIconRule.name(of: .primary) == nil)
        #expect(KidsIconRule.name(of: .kids) == KidsIconRule.alternateName)
        #expect(KidsIconRule.icon(named: nil) == .primary)
        #expect(KidsIconRule.icon(named: KidsIconRule.alternateName) == .kids)
        #expect(KidsIconRule.icon(named: "Something else") == .primary)
    }

    @Test func switchesToTheKidsIconOnceKidsModeLasts() async {
        let surface = FakeSurface()
        let switcher = KidsIconSwitcher(surface: surface, settle: .milliseconds(20))
        switcher.update(state(kids: true))
        #expect(surface.shown.isEmpty)
        await switcher.pending?.value
        #expect(surface.shown == [.kids])
    }

    @Test func asksNothingWhenTheIconShowsAlready() async {
        let surface = FakeSurface()
        surface.current = .kids
        let switcher = KidsIconSwitcher(surface: surface, settle: .milliseconds(1))
        switcher.update(state(kids: true))
        #expect(switcher.pending == nil)
        surface.current = .primary
        switcher.update(state(kids: false))
        #expect(switcher.pending == nil)
        #expect(surface.shown.isEmpty)
    }

    @Test func aMomentInKidsModeChangesNothing() async {
        let surface = FakeSurface()
        let switcher = KidsIconSwitcher(surface: surface, settle: .milliseconds(50))
        switcher.update(state(kids: true))
        let waiting = switcher.pending
        switcher.update(state(kids: false))
        await waiting?.value
        #expect(switcher.pending == nil)
        #expect(surface.shown.isEmpty)
    }

    @Test func theSameWishKeepsItsPlaceInTheWait() async {
        let surface = FakeSurface()
        let switcher = KidsIconSwitcher(surface: surface, settle: .milliseconds(20))
        switcher.update(state(kids: true))
        let waiting = switcher.pending
        // Another change that wants the same icon does not start the wait again.
        switcher.update(state(kids: true, on: true))
        #expect(switcher.pending == waiting)
        await waiting?.value
        #expect(surface.shown == [.kids])
    }

    @Test func waitsForTheAppInFrontAndTheFilmToEnd() async {
        let surface = FakeSurface()
        let switcher = KidsIconSwitcher(surface: surface, settle: .milliseconds(10))
        switcher.update(state(kids: true, active: false))
        #expect(switcher.pending == nil)
        switcher.update(state(kids: true, playing: true))
        #expect(switcher.pending == nil)
        // Going to the background stops a wait that had begun.
        switcher.update(state(kids: true))
        let waiting = switcher.pending
        switcher.update(state(kids: true, active: false))
        await waiting?.value
        #expect(surface.shown.isEmpty)
        switcher.update(state(kids: true))
        await switcher.pending?.value
        #expect(surface.shown == [.kids])
    }

    @Test func aGrownUpTakingOverBringsThePrimaryBack() async {
        let surface = FakeSurface()
        surface.current = .kids
        let switcher = KidsIconSwitcher(surface: surface, settle: .milliseconds(10))
        switcher.update(state(kids: false))
        await switcher.pending?.value
        #expect(surface.shown == [.primary])
    }

    @Test func theSettingOffKeepsOrRestoresThePrimary() async {
        let surface = FakeSurface()
        let switcher = KidsIconSwitcher(surface: surface, settle: .milliseconds(10))
        switcher.update(state(kids: true, on: false))
        #expect(switcher.pending == nil)
        surface.current = .kids
        switcher.update(state(kids: true, on: false))
        await switcher.pending?.value
        #expect(surface.shown == [.primary])
    }

    @Test func doesNothingWhereTheIconCannotChange() {
        let surface = FakeSurface()
        surface.canSwitch = false
        let switcher = KidsIconSwitcher(surface: surface, settle: .zero)
        switcher.update(state(kids: true))
        #expect(switcher.pending == nil)
    }
}
