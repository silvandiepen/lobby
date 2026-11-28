// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import Testing

@testable import Lobby

/// Which pages of Settings each person sees, and how a search finds them.
@Suite struct SettingsMapTests {
    private let serverAdmin = SettingsAudience(level: .admin)
    private let householdAdmin = SettingsAudience(level: .householdAdmin)
    private let viewer = SettingsAudience(level: .viewer)
    private let kid = SettingsAudience(level: .viewer, isKidsMode: true)

    @Test func aServerAdminSeesEveryGroup() {
        let groups = SettingsMap.groups(for: serverAdmin).map(\.group)
        #expect(groups == [.you, .device, .household, .server, .about])
        let pages = SettingsMap.pages(for: serverAdmin)
        #expect(pages.contains(.libraryFolders))
        #expect(pages.contains(.households))
        #expect(pages.contains(.devices))
        // The server's page has all of it; the household's overview is for a household admin.
        #expect(!pages.contains(.householdStats))
    }

    @Test func aHouseholdAdminManagesTheHouseholdAndNotTheServer() {
        let groups = SettingsMap.groups(for: householdAdmin).map(\.group)
        #expect(groups == [.you, .device, .household, .about])
        let pages = SettingsMap.pages(for: householdAdmin)
        #expect(pages.contains(.devices) && pages.contains(.viewers) && pages.contains(.kids))
        #expect(pages.contains(.householdStats))
        #expect(!pages.contains(.categories))
    }

    @Test func aViewerSeesOnlyTheirOwnThings() {
        let groups = SettingsMap.groups(for: viewer).map(\.group)
        #expect(groups == [.you, .device, .about])
        let pages = SettingsMap.pages(for: viewer)
        #expect(!pages.contains { $0.group == .household || $0.group == .server })
        #expect(pages.contains(.playback) && pages.contains(.downloads))
    }

    @Test func aKidSeesOnlyWhatTheAppIs() {
        #expect(SettingsMap.pages(for: kid) == [.about])
        // Kids mode wins over the device's level.
        #expect(SettingsMap.pages(for: SettingsAudience(level: .admin, isKidsMode: true)) == [.about])
    }

    @Test func beforeAServerOrAViewerOnlyServersAndAbout() {
        let unpaired = SettingsAudience(level: .viewer, isConnected: false, hasViewer: false)
        #expect(SettingsMap.pages(for: unpaired) == [.servers, .about])
        let noViewer = SettingsAudience(level: .viewer, hasViewer: false)
        #expect(!SettingsMap.pages(for: noViewer).contains { $0.group == .you })
    }

    @Test func whatAnOlderServerDoesNotKeepIsLeftOut() {
        var older = viewer
        older.offersSubtitles = false
        older.offersSkipping = false
        let pages = SettingsMap.pages(for: older)
        #expect(!pages.contains(.subtitles) && !pages.contains(.skipping))
        #expect(pages.contains(.playback))
    }

    @Test func theMacHasCategoriesInItsSidebar() {
        var mac = serverAdmin
        mac.sidebarHasCategories = true
        #expect(!SettingsMap.pages(for: mac).contains(.categories))
        #expect(SettingsMap.pages(for: serverAdmin).contains(.categories))
    }

    @Test func everyPageHasAOneLineNote() {
        for page in SettingsPage.allCases {
            #expect(!page.summary.isEmpty)
            #expect(!page.summary.contains("\n"))
        }
    }

    @Test func eachServerSettingIsOnOnePage() {
        let all = SettingsPage.allCases.flatMap(\.serverKeys)
        #expect(Set(all).count == all.count, "A key is on two pages.")
    }

    @Test func aSettingOfANewerServerShowsUnderAdvanced() {
        let available = ["serverName", "backup.keep", "something.new"]
        #expect(SettingsPage.advanced.rowKeys(among: available) == ["something.new"])
        #expect(SettingsPage.backups.rowKeys(among: available) == ["backup.keep"])
        // The folder lists are drawn by the page itself, not as rows; their changes are still the page's.
        #expect(SettingsPage.libraryFolders.rowKeys(among: ["roots", "rescanMinutes"]) == ["rescanMinutes"])
        #expect(SettingsPage.libraryFolders.draftKeys(among: ["roots"]).contains("roots"))
    }

    @Test func searchFindsAPageByWhatIsOnIt() {
        #expect(SettingsMap.search("tmdb", for: serverAdmin).first == .matching)
        #expect(SettingsMap.search("mobile data", for: viewer) == [.downloads])
        // Not what the viewer may not see.
        #expect(!SettingsMap.search("tmdb", for: viewer).contains(.matching))
        // The server's own words for a setting find its page too.
        #expect(SettingsMap.search("zebra", for: serverAdmin) { $0 == .backups ? ["Zebra"] : [] } == [.backups])
        #expect(SettingsMap.search("qwxzq", for: serverAdmin).isEmpty)
    }
}
