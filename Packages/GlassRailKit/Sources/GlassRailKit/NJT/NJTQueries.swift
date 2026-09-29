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

    /// Planner lookups start now and 75, 150 and 225 minutes out, so one
    /// refresh covers the next few hours (the planner returns a handful of
    /// itineraries per request).
    public static let plannerOffsetsMinutes = [0, 75, 150, 225]

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
