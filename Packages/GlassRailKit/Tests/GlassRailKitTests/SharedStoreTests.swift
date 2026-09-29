import XCTest
@testable import GlassRailKit

final class SharedStoreTests: XCTestCase {
    var suiteName = ""
    var store: SharedStore!

    override func setUp() {
        super.setUp()
        suiteName = "GlassRailKitTests.\(UUID().uuidString)"
        store = SharedStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDestinationDefaultsToHobokenAndOnlyAcceptsConfiguredTerminals() {
        XCTAssertEqual(store.destinationId, "hoboken")
        store.destinationId = "penn"
        XCTAssertEqual(store.destinationId, "penn")
        store.destinationId = "baystreet"
        XCTAssertEqual(store.destinationId, "penn")
    }

    func testPinSurvivesARelaunchUntilItsTTL() {
        let now = date("2026-08-04T18:00:00.000Z")
        let pin = Pin(dirKey: "watchung|hoboken", key: "watchung|hoboken|1012")
        let trip = makeTrip(trainId: "1012", departure: now.addingTimeInterval(-600), arrival: now.addingTimeInterval(1800))
        store.savePin(pin, trip: trip, now: now)
        XCTAssertEqual(store.restorePin(now: now.addingTimeInterval(3600))?.trip, trip)
        XCTAssertNil(store.restorePin(now: now.addingTimeInterval(PinStore.ttl + 1)))
        store.savePin(nil, trip: nil, now: now)
        XCTAssertNil(store.pinRaw)
    }

    func testSnapshotRoundTrips() {
        let now = date("2026-08-04T18:00:00.000Z")
        let payload = Payload(
            generatedAt: now,
            source: PayloadSource(kind: .live, detail: "Live"),
            trips: [makeTrip(departure: now, arrival: nil, legTrainIds: ["1074"], status: .delayed, statusNote: "Delayed 6 min")]
        )
        let runs: Runs = ["1074": [TrainStop(name: "Watchung Avenue", time: now, departed: false, status: "Late", note: nil)]]
        store.snapshot = SharedStore.Snapshot(payload: payload, runs: runs)
        XCTAssertEqual(store.snapshot, SharedStore.Snapshot(payload: payload, runs: runs))
        store.snapshot = nil
        XCTAssertNil(store.snapshot)
    }

    func testReadsTheAppGroupFromInfoPlistWithAFallback() {
        XCTAssertEqual(SharedStore.appGroup(in: Bundle(for: SharedStoreTests.self)), SharedStore.defaultAppGroup)
    }
}
