import Foundation

/// NJ Transit's public GraphQL endpoint and the three queries v4 sent to it,
/// copied verbatim from lib/njt.ts. No API key. v4 set exactly one header,
/// `content-type: application/json`, and so does this client.
public enum NJTQueries {
    public static let endpoint = URL(string: "https://www.njtransit.com/api/graphql/graphql")!

    public static let tripPlanner = """

      query TripPlannerSchedule(
        $origin: String!
        $destination: String!
        $timeOption: String
        $date: String
        $time: String
        $accessible: Boolean
        $travelMode: String
        $maxWalkingDistance: String
        $minimizeTime: String
      ) {
        getTripPlannerSchedule(
          origin: $origin
          destination: $destination
          timeOption: $timeOption
          date: $date
          time: $time
          accessible: $accessible
          travelMode: $travelMode
          maxWalkingDistance: $maxWalkingDistance
          minimizeTime: $minimizeTime
        ) {
          duration
          legs {
            route
            routeType
            sign
            onStopDescription
            onStopTime
            offStopDescription
            offStopTime
            block
          }
        }
      }

    """

    public static let departureBoard = """

      query DepartureScreen($station: String!) {
        getTrainDepartureScreens(station: $station) {
          items {
            departureDate
            destination
            inlineMessage
            lineAbbreviation
            status
            track
            trainID
          }
        }
      }

    """

    public static let trainStops = """

      query TrainStopList($train: String!) {
        getTrainStopList(train: $train) {
          name
          time
          status
          departed
          dropOff
        }
      }

    """

    /// NJ Transit's travel alerts, grouped by rail line ("BNTN" is the
    /// Montclair-Boonton Line), as its own app shows them.
    public static let railAlerts = """
      query RailAlerts {
        getRailAlertsAdvisories {
          abbreviation
          travelAlerts {
            body
          }
        }
      }
    """

    /// Planner lookups start now and 75, 150 and 225 minutes out, so one
    /// refresh reaches the next few hours. Each answers with only three
    /// itineraries, ranked by arrival, so on their own they skip trains (on
    /// 5 October at 2:22 PM, with eight per-train lookups as well, the app
    /// found 18 of 37 ways home from Hoboken in the next six hours); one
    /// more lookup per train on the home station's board fills those in
    /// (see `NJTClient.plannerSeeds`). The lookups after the first are
    /// pinned to the quarter hour after their time and reused like the
    /// per-train ones, so what they find doesn't come and go from one
    /// refresh to the next.
    public static let plannerOffsetsMinutes = [0, 75, 150, 225]

    /// Where the clock lookups after the first are pinned: the quarter hour.
    public static let clockLookupStep: TimeInterval = 15 * 60

    /// Per-train lookups reach this far ahead: every train on the home
    /// station's board (Watchung Avenue's listed 19 trains both ways, five
    /// hours of them, at 2:22 PM on a weekday).
    public static let seedHorizonMinutes = 360

    /// Per-train lookups (see `NJTClient.plannerSeeds`) for the direction on
    /// screen: every train this way on the home station's board, soonest
    /// first, up to this many.
    public static let seedsForShownDirection = 24
    /// Per-train lookups for each other direction, so a flip or a change of
    /// terminal shows every train straight away. None on the first refresh
    /// after opening, so the board on screen isn't kept waiting.
    public static let seedsForOtherDirection = 24
    /// How long a per-train (or pinned clock) lookup's answer is reused. Each
    /// sits at a fixed time, so the same lookups recur refresh after refresh
    /// and a timetable doesn't change in between; live status comes from the
    /// departure boards.
    public static let seedCacheLifetime: TimeInterval = 10 * 60
    /// How long such an answer is kept to stand in when asking again fails,
    /// so a train doesn't drop off the board over one lost request.
    public static let plannerFallbackLimit: TimeInterval = 30 * 60

    /// "On a train that's already left?" asks the planner for trips leaving
    /// this many minutes ago (three itineraries each), only when the rider
    /// opens it: with the trips remembered from earlier refreshes, that
    /// covers the trains of the last hour still under way.
    public static let recentRideLookbackMinutes = [70, 45, 20]

    /// Upper bound on trains per stop-list batch, so one refresh can't fan out.
    public static let maxStopListTrains = 8
}

/// A GraphQL variable value. Only the two kinds v4 sent are needed.
public enum GQLValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)

    var jsonObject: Any {
        switch self {
        case .string(let text): return text
        case .bool(let flag): return flag
        }
    }
}

public enum NJTError: Error, Equatable, LocalizedError, Sendable {
    case http(Int)
    case graphQL(String)
    case missingData
    case notJSON
    case feed(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "NJT public feed HTTP \(status)"
        case .graphQL(let message): return message
        case .missingData: return "NJT response missing data"
        case .notJSON: return "NJT response was not JSON"
        case .feed(let message): return message
        }
    }
}
