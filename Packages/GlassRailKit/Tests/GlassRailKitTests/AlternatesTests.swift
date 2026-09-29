import XCTest
@testable import GlassRailKit

/// Port of tests/alternates.test.ts (10 cases).
final class AlternatesTests: XCTestCase {
    let home = "watchung"
    let fallbacks = ["baystreet"]

    private func pair(_ from: String, _ to: String) -> ODPair { ODPair(fromId: from, toId: to) }

    // alternateRoutes: what to offer the rider when their station is dead

    func testSubstitutesTheOriginWhenLeavingFromHome() {
        XCTAssertEqual(Alternates.alternateRoutes(fromId: "watchung", toId: "hoboken", homeId: home, fallbackIds: fallbacks), [pair("baystreet", "hoboken")])
    }

    func testSubstitutesTheDestinationWhenHeadingHome() {
        XCTAssertEqual(Alternates.alternateRoutes(fromId: "hoboken", toId: "watchung", homeId: home, fallbackIds: fallbacks), [pair("hoboken", "baystreet")])
    }

    func testOffersEachFallbackInOrderOfPreference() {
        XCTAssertEqual(
            Alternates.alternateRoutes(fromId: "watchung", toId: "hoboken", homeId: home, fallbackIds: ["baystreet", "glenridge"]),
            [pair("baystreet", "hoboken"), pair("glenridge", "hoboken")]
        )
    }

    func testOffersNothingWhenHomeIsNotPartOfTheJourney() {
        XCTAssertEqual(Alternates.alternateRoutes(fromId: "hoboken", toId: "penn", homeId: home, fallbackIds: fallbacks), [])
    }

    func testOffersNothingWithNoFallbacksConfigured() {
        XCTAssertEqual(Alternates.alternateRoutes(fromId: "watchung", toId: "hoboken", homeId: home, fallbackIds: []), [])
    }

    func testNeverSuggestsAFallbackThatIsTheOtherEndOfTheTrip() {
        XCTAssertEqual(Alternates.alternateRoutes(fromId: "watchung", toId: "baystreet", homeId: home, fallbackIds: fallbacks), [])
    }

    // substitutePairs: which extra lookups to make

    var pairs: [ODPair] {
        [pair("watchung", "hoboken"), pair("hoboken", "watchung"), pair("watchung", "penn"), pair("penn", "watchung")]
    }

    func testAsksForNothingExtraWhileHomeHasService() {
        XCTAssertEqual(Alternates.substitutePairs(pairs, emptyPairKeys: [], homeId: home, fallbackIds: fallbacks), [])
    }

    func testCoversOnlyTheDirectionsThatCameBackEmpty() {
        XCTAssertEqual(
            Alternates.substitutePairs(pairs, emptyPairKeys: ["watchung|hoboken"], homeId: home, fallbackIds: fallbacks),
            [pair("baystreet", "hoboken")]
        )
    }

    func testCoversBothDirectionsWhenTheWholeStationIsOut() {
        let empty: Set<String> = ["watchung|hoboken", "hoboken|watchung", "watchung|penn", "penn|watchung"]
        XCTAssertEqual(
            Alternates.substitutePairs(pairs, emptyPairKeys: empty, homeId: home, fallbackIds: fallbacks),
            [pair("baystreet", "hoboken"), pair("hoboken", "baystreet"), pair("baystreet", "penn"), pair("penn", "baystreet")]
        )
    }

    func testDoesNotDuplicateASubstituteAlreadyBeingFetched() {
        let withAlt = pairs + [pair("baystreet", "hoboken")]
        XCTAssertEqual(Alternates.substitutePairs(withAlt, emptyPairKeys: ["watchung|hoboken"], homeId: home, fallbackIds: fallbacks), [])
    }
}
