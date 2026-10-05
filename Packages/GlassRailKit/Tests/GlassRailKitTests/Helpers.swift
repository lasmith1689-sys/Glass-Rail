import Foundation
import XCTest
@testable import GlassRailKit

/// `new Date("2026-08-03T21:08:00.000Z")`
func date(_ iso: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
    guard let value = ISOTime.date(from: iso) else {
        XCTFail("Bad ISO date in test: \(iso)", file: file, line: line)
        return Date(timeIntervalSince1970: 0)
    }
    return value
}

/// A trip with v4's test defaults (`makeTrip` in the vitest suites).
func makeTrip(
    fromId: String = "watchung",
    toId: String = "hoboken",
    trainId: String? = "1074",
    departure: Date,
    arrival: Date?,
    track: String? = "2",
    transferCount: Int = 0,
    transferAt: [String] = [],
    legTrainIds: [String]? = nil,
    note: String? = nil,
    status: TripStatus? = nil,
    statusNote: String? = nil
) -> Trip {
    Trip(
        fromId: fromId,
        toId: toId,
        trainId: trainId,
        departure: departure,
        arrival: arrival,
        track: track,
        transferCount: transferCount,
        transferAt: transferAt,
        legTrainIds: legTrainIds,
        note: note,
        status: status,
        statusNote: statusNote
    )
}

let watchungRef = StationRef(name: "Watchung Avenue", shortLabel: "Watchung Ave")
let hobokenRef = StationRef(name: "Hoboken Terminal", shortLabel: "Hoboken")
let pennRef = StationRef(name: "New York Penn Station", shortLabel: "Penn Station NY")

/// Loads a JSON fixture from Tests/GlassRailKitTests/Fixtures.
func fixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url) else {
        XCTFail("Missing fixture \(name).json", file: file, line: line)
        return Data()
    }
    return data
}

func fixtureJSON(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> JSON {
    (try? JSON.parse(fixture(name, file: file, line: line))) ?? .null
}

/// A clock a test can move between refreshes.
final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        value = start
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
