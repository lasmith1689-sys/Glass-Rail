import XCTest
@testable import GlassRailKit

/// Any NJ Transit rail station as home (Settings), Watchung Avenue by default.
final class HomeStationTests: XCTestCase {
    override func tearDown() {
        HomeStation.override = nil
        super.tearDown()
    }

    func testWatchungAvenueIsHomeByDefault() {
        XCTAssertEqual(UserConfig.homeId, "watchung")
        XCTAssertEqual(UserConfig.home.plannerName, "Watchung Avenue Station")
        XCTAssertEqual(UserConfig.alertLines, ["BNTN", "BNTNM"])
        XCTAssertEqual(UserConfig.fallbackOriginIds, ["baystreet"])
    }

    func testTheCatalogKnowsEveryStationByBothNames() {
        XCTAssertGreaterThan(Stations.catalog.count, 150)
        XCTAssertEqual(Set(Stations.catalog.map(\.id)).count, Stations.catalog.count, "ids are unique")
        for station in Stations.catalog {
            XCTAssertFalse(station.name.isEmpty)
            XCTAssertFalse(station.plannerName.isEmpty, station.name)
            XCTAssertFalse(station.lines.isEmpty, station.name)
            XCTAssertEqual(station.lineTitles.count, station.lines.count, station.name)
            XCTAssertFalse(station.alertLines.isEmpty, station.name)
        }
        // The four the app always knew keep their own names.
        XCTAssertEqual(Stations.station("hoboken")?.name, "Hoboken Terminal")
        XCTAssertEqual(Stations.station("penn")?.shortLabel, "Penn Station NY")
        XCTAssertEqual(Stations.station("watchung")?.lines, ["MOBO"])
        // Names the planner only knows its own way, checked live.
        XCTAssertEqual(Stations.station("montclairstateu")?.plannerName, "Montclair State University Station")
        XCTAssertEqual(Stations.station("secaucus")?.name, "Secaucus")
        XCTAssertEqual(Stations.station("secaucus")?.plannerName, "Secaucus Junction Station")
        // Home can be any station but a destination.
        XCTAssertFalse(Stations.homeChoices.contains { UserConfig.destinationIds.contains($0.id) })
        XCTAssertTrue(Stations.homeChoices.contains { $0.id == "watchung" })
    }

    func testAnotherHomeChangesTheTripsAndAlertsButNotTheDestinations() {
        HomeStation.override = "summit"
        XCTAssertEqual(UserConfig.homeId, "summit")
        XCTAssertEqual(UserConfig.home.name, "Summit")
        XCTAssertEqual(UserConfig.alertLines, ["MNE", "MNEG"])
        XCTAssertEqual(UserConfig.fallbackOriginIds, [], "Bay Street is Watchung Avenue's fallback")
        XCTAssertEqual(Alternates.defaultPairs().map(\.key), ["summit|hoboken", "hoboken|summit", "summit|penn", "penn|summit"])
        let sample = SampleFixture.payload().trips
        XCTAssertFalse(sample.isEmpty)
        XCTAssertTrue(sample.allSatisfy { $0.fromId == "summit" || $0.toId == "summit" }, "the sample follows home")
        // A station the catalog doesn't know, or a destination, is no home.
        HomeStation.override = "nowhere"
        XCTAssertEqual(UserConfig.homeId, "watchung")
        HomeStation.override = "penn"
        XCTAssertEqual(UserConfig.homeId, "watchung")
    }

    func testARefreshForAnotherHomeAsksNJTransitAboutThatStation() async {
        HomeStation.override = "summit"
        let fake = FakeNJT { operation, _ in
            operation == "board" ? FakeNJT.emptyBoard : FakeNJT.emptyPlanner
        }
        let fixed = date("2026-10-06T12:00:00.000Z")
        _ = try? await NJTClient(transport: fake, clock: { fixed }, retryDelay: 0).fetchLivePayload()
        let boards = Set(fake.calls.filter { $0.operation == "board" }.map { $0.variables["station"].jsString })
        let origins = Set(fake.calls.filter { $0.operation == "planner" }.map { $0.variables["origin"].jsString })
        XCTAssertTrue(boards.contains("Summit"), "\(boards)")
        XCTAssertFalse(boards.contains("Watchung Avenue"))
        XCTAssertTrue(origins.contains("Summit Station"), "\(origins)")
        XCTAssertFalse(origins.contains("Watchung Avenue Station"))
    }
}
