// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// The statistics pages: what they say of a viewer's month and of the server, and what they ask.
@MainActor
@Suite struct StatsTests {
    /// A Thursday in January: Wednesday's evening and a Saturday afternoon.
    static let viewer = #"""
    {"viewer":{"id":"alex","name":"Alex","color":"blue","avatar":null,"kids":false},"keptDays":730,"simple":false,
     "range":{"name":"month","timeZone":"Europe/Amsterdam","firstDay":"2026-12-16","lastDay":"2027-01-14","from":1797375600000,"to":1799928000000},
     "totals":{"watchedMs":9000000,"sessions":3,"titles":2,"filmsFinished":1,"episodesFinished":2,"listenedMs":1800000,"tracksPlayed":9,"activeDays":2},
     "days":[{"day":"2027-01-13","watchedMs":5400000,"listenedMs":0},{"day":"2027-01-14","watchedMs":3600000,"listenedMs":1800000}],
     "months":[{"month":"2026-12","watchedMs":0,"listenedMs":0},{"month":"2027-01","watchedMs":9000000,"listenedMs":1800000}],
     "heatmap":[[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5400000,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3600000,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]],
     "when":{"mornings":0,"afternoons":3600000,"evenings":5400000,"nights":0,"weekdays":5400000,"weekends":3600000},
     "topTitles":[{"itemId":"up","title":"Up","kind":"movie","watchedMs":5400000,"sessions":1,"lastAt":1799900000000},{"itemId":"bluey","title":"Bluey","kind":"show","watchedMs":3600000,"sessions":2,"lastAt":1799920000000}],
     "series":[{"itemId":"bluey","title":"Bluey","episodesWatched":2,"episodes":10,"lastEpisodeId":"b-2","lastEpisode":"S1 E2","lastAt":1799920000000}],
     "genres":[{"id":"1","name":"Animation","watchedMs":9000000}],"studios":[],"categories":[],
     "streak":{"current":2,"longest":4},
     "music":{"listenedMs":1800000,"plays":9,"topAlbums":[{"id":"al-1","title":"Abbey Road","artist":"The Beatles","coverId":null,"listenedMs":1800000,"plays":9}],"topArtists":[{"name":"The Beatles","listenedMs":1800000}]},
     "playOnSessions":1,"roads":{"home":5400000,"tailnet":3600000,"relay":0,"direct":0,"unknown":0},
     "deliveries":{"direct":9000000,"prepared":0,"download":0,"unknown":0},
     "devices":[{"id":"dev-1","name":"Test iPhone","platform":"ios","watchedMs":9000000}],
     "history":[{"id":"s-1","itemId":"b-2","titleId":"bluey","title":"Bluey","subtitle":"S1 E2 · Hospital","startedAt":1799918000000,"endedAt":1799920000000,"timed":true,"watchedMs":1800000,"completed":true,"device":"Test iPhone","road":"tailnet","delivery":"prepared","playOnFrom":null},
                {"id":"s-0","itemId":"up","titleId":"up","title":"Up","subtitle":"2009","startedAt":1799890000000,"endedAt":1799900000000,"timed":true,"watchedMs":5400000,"completed":true,"device":"Test iPhone","road":"home","delivery":"direct","playOnFrom":"Phone"}]}
    """#

    static let server = #"""
    {"keptDays":730,"range":{"name":"month","timeZone":"UTC","firstDay":"2027-01-13","lastDay":"2027-01-14","from":1799798400000,"to":1799928000000},
     "household":null,"totals":{"watchedMs":9000000,"sessions":3,"viewers":2,"devices":2,"listenedMs":0,"tracksPlayed":0},
     "days":[{"day":"2027-01-13","watchedMs":5400000,"sessions":1,"viewers":1},{"day":"2027-01-14","watchedMs":3600000,"sessions":2,"viewers":2}],
     "heatmap":[[],[],[],[],[],[],[]],"hours":[],
     "topTitles":[{"itemId":"up","title":"Up","kind":"movie","viewers":2,"sessions":2,"watchedMs":5400000}],
     "viewers":[{"id":"alex","name":"Alex","color":"blue","avatar":null,"kids":false,"watchedMs":5400000,"sessions":2,"lastAt":1799900000000}],
     "devices":[{"id":"dev-1","name":"Test iPhone","platform":"ios","watchedMs":9000000,"sessions":3}],
     "households":[{"id":"owner","name":"Home","owner":true,"watchedMs":5400000,"sessions":2,"viewers":1,"devices":1,"bytesSent":3000000000},{"id":"h-2","name":"The neighbours","owner":false,"watchedMs":3600000,"sessions":1,"viewers":1,"devices":1,"bytesSent":1000000000}],
     "roads":{"home":5400000,"tailnet":0,"relay":3600000,"direct":0,"unknown":0},"deliveries":{"direct":5400000,"prepared":3600000,"download":0,"unknown":0},
     "traffic":{"homeBytes":3000000000,"awayBytes":1000000000,"byRoad":{"home":3000000000,"relay":1000000000},"days":[]},
     "preparations":{"count":2,"converted":1,"ahead":0,"timeMs":600000,"bytes":2000000000},
     "conversions":{"done":1,"failed":0,"waiting":0,"timeMs":3600000,"savedBytes":500000000,"savedInAllBytes":500000000},
     "library":{"films":10,"shows":2,"episodes":30,"months":[{"month":"2027-01","films":1,"episodes":3}]},
     "playOn":{"sessions":1,"watchedMs":1800000,"targets":[{"id":"tv","name":"Living Room","sessions":1}]},
     "storage":{"playbackCacheBytes":5000000000,"playbackCacheMaxBytes":20000000000,"databaseBytes":10000000}}
    """#

    // MARK: What the pages say

    @Test func saysAMonthInWords() throws {
        let stats = try LobbyJSON.decoder().decode(ViewerStats.self, from: Data(Self.viewer.utf8))
        #expect(StatsSummary.headline(.month) == "Your Month in Lobby")
        #expect(StatsSummary.headline(.year, name: "Mila") == "Mila’s Year in Lobby")
        #expect(StatsSummary.duration(9_000_000) == "2 h 30 min")
        #expect(StatsSummary.duration(45 * 60_000) == "45 min")
        #expect(StatsSummary.duration(7_200_000) == "2 h")
        #expect(StatsSummary.duration(0) == "None")

        let cards = StatsSummary.cards(stats)
        #expect(cards.map(\.id) == ["watched", "top", "finished", "when", "streak", "music"])
        #expect(cards.first?.value == "2 h 30 min")
        #expect(cards.first?.detail == "On 2 days")
        #expect(cards[1].value == "Up")
        #expect(cards[2].value == "1 film")
        #expect(cards[2].detail == "2 episodes")
        // Wednesday evenings, around eight.
        #expect(cards[3].value == "Wednesdays")
        #expect(cards[3].detail == "Evenings, around 20:00")
        #expect(cards[4].value == "2 days")
        #expect(cards[5].detail == "Mostly Abbey Road")

        #expect(StatsSummary.busiestWeekday(stats.heatmap) == 2)
        #expect(StatsSummary.busiestHour(stats.heatmap) == 20)
        #expect(StatsSummary.busiestWeekday(Array(repeating: Array(repeating: 0, count: 24), count: 7)) == nil)
        #expect(StatsSummary.awayShare(stats.roads) == 0.4)
        let history = try #require(stats.history)
        #expect(StatsSummary.how(history[0]) == "Test iPhone · Over Tailscale · Prepared")
        #expect(StatsSummary.how(history[1]) == "Test iPhone · At home · As it is · Sent from Phone")
    }

    @Test func drawsDaysForAMonthAndMonthsForAYear() throws {
        let stats = try LobbyJSON.decoder().decode(ViewerStats.self, from: Data(Self.viewer.utf8))
        let days = StatsSummary.bars(days: stats.days, months: stats.months, range: stats.range)
        #expect(days.map(\.id) == ["2027-01-13", "2027-01-14"])
        #expect(days[1].watchedHours == 1)
        #expect(days[1].listenedHours == 0.5)
        var year = stats.range
        year.name = .year
        let months = StatsSummary.bars(days: stats.days, months: stats.months, range: year)
        #expect(months.map(\.id) == ["2026-12", "2027-01"])
        #expect(months[1].watchedHours == 2.5)
        // Noon of the day in the page's zone, so the bar stands on that day wherever it is drawn.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        #expect(calendar.component(.day, from: days[0].date) == 13)
        #expect(StatsSummary.heatCells(stats.heatmap).count == 7 * 24)
    }

    @Test func saysTheServersMonth() throws {
        let stats = try LobbyJSON.decoder().decode(ServerStats.self, from: Data(Self.server.utf8))
        let cards = StatsSummary.cards(stats)
        #expect(cards.map(\.id) == ["watched", "viewers", "sent", "prepared", "converted", "playOn"])
        #expect(cards[2].detail == "25% away from home")
        #expect(cards[5].detail == "Mostly Living Room")
    }

    // MARK: What they ask

    @Test func aViewerSeesTheirOwnAndTakesOneOut() async throws {
        let test = try TestApp()
        test.household.change { $0.viewerStats = Self.viewer }
        let app = try await test.launchPaired(as: "alex")
        let model = ViewerStatsModel(app: app, profileID: "alex")
        await model.load()
        #expect(model.isOwn)
        #expect(model.headline == "Your Month in Lobby")
        #expect(model.stats?.totals.watchedMs == 9_000_000)
        #expect(model.canRemove)
        // A viewer's device does not forget a whole history.
        #expect(!model.canForget)
        await model.forget()
        #expect(test.household.current.forgottenViewers.isEmpty)

        await model.select(.year)
        #expect(test.household.current.statsAsked == ["viewers/alex?range=month", "viewers/alex?range=year"])

        let sitting = try #require(model.stats?.history?.first)
        await model.remove(sitting)
        #expect(test.household.current.removedSittings == ["alex/s-1"])
    }

    @Test func aManagerForgetsAViewersHistory() async throws {
        let test = try TestApp(Household(.init(
            device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))))
        test.household.change { $0.viewerStats = Self.viewer.replacingOccurrences(of: #""kids":false"#, with: #""kids":true"#) }
        let app = try await test.launchPaired(as: "alex")
        let model = ViewerStatsModel(app: app, profileID: "kids")
        await model.load()
        #expect(!model.isOwn)
        #expect(model.isKid)
        #expect(model.headline == "Alex’s Month in Lobby")
        #expect(model.whenSummary == "60% in the evening or later, 40% at the weekend.")
        #expect(model.canForget)
        await model.forget()
        #expect(test.household.current.forgottenViewers == ["kids"])
    }

    @Test func anOlderServerHasNoStatistics() async throws {
        let test = try TestApp()
        let app = try await test.launchPaired(as: "alex")
        let model = ViewerStatsModel(app: app, profileID: "alex")
        await model.load()
        #expect(model.isUnavailable)
        #expect(model.stats == nil)
        #expect(model.problem == nil)
    }

    @Test func aServerAdminOpensAGuestHousehold() async throws {
        let test = try TestApp(Household(.init(
            device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))))
        test.household.change { $0.serverStats = Self.server }
        let app = try await test.launchPaired(as: "alex")
        let model = ServerStatsModel(app: app)
        await model.load()
        #expect(model.stats?.households.count == 2)
        #expect(model.cacheFill == 0.25)
        await model.open(household: "h-2")
        #expect(model.householdID == "h-2")
        await model.open(household: "owner")
        #expect(model.householdID == nil)
        #expect(test.household.current.statsAsked == [
            "server?range=month&household=", "server?range=month&household=h-2", "server?range=month&household=",
        ])
    }

    @Test func aViewerDeviceHasNoServerPage() async throws {
        let test = try TestApp()
        test.household.change { $0.serverStats = Self.server }
        let app = try await test.launchPaired(as: "alex")
        let model = ServerStatsModel(app: app)
        await model.load()
        #expect(model.stats == nil)
        #expect(test.household.current.statsAsked.isEmpty)
    }
}
