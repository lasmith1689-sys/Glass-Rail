import Foundation

/// Connects the track checker to NJ Transit from Settings: a one-time setup
/// code and the rider's RailData developer login, sent once to the
/// penn-connect function (supabase/README.md). NJ Transit has to accept the
/// login before the checker keeps it, encrypted; the phone keeps nothing.
public struct PennConnect: Sendable {
    public static let endpoint = URL(string: "https://hhzizoiftyuvqgscyqxh.supabase.co/functions/v1/penn-connect")!

    public enum Outcome: Equatable, Sendable {
        case connected
        case refused(Refusal)
    }

    /// Why the checker didn't connect, as penn-connect says it.
    public enum Refusal: String, Equatable, Sendable {
        case code
        case codeUsed = "code-used"
        case codeExpired = "code-expired"
        case codeLocked = "code-locked"
        case login
        case busy
        case unreachable

        /// What Settings says under the Connect button.
        public var message: String {
            switch self {
            case .code: return "That setup code isn't right. Check it and try again."
            case .codeUsed: return "That setup code has already been used. Ask for a new one."
            case .codeExpired: return "That setup code has expired. Ask for a new one."
            case .codeLocked: return "That setup code was tried too many times. Ask for a new one."
            case .login: return "NJ Transit didn't accept that username and password."
            case .busy: return "NJ Transit allows only a few sign-ins a day. Try again in a few hours."
            case .unreachable: return "Couldn't reach NJ Transit. Check your connection and try again."
            }
        }
    }

    /// What still has to be filled in before Connect can go, first one first.
    public enum Missing: Equatable, Sendable {
        case code, username, password

        /// What the Connect page says when it's tapped too soon.
        public var message: String {
            switch self {
            case .code: return "The setup code is 6 letters and numbers."
            case .username: return "Enter your RailData username."
            case .password: return "Enter your RailData password."
            }
        }
    }

    public static func missing(code: String, username: String, password: String) -> Missing? {
        if normalized(code: code).count != 6 { return .code }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .username }
        if password.isEmpty { return .password }
        return nil
    }

    /// Sends one request: the reply's status and body. Tests stand in for
    /// the network.
    public var send: @Sendable (URLRequest) async throws -> (Int, Data)

    public init(send: @escaping @Sendable (URLRequest) async throws -> (Int, Data) = PennConnect.urlSession) {
        self.send = send
    }

    public func connect(code: String, username: String, password: String) async -> Outcome {
        do {
            let (status, body) = try await send(try Self.request(code: code, username: username, password: password))
            return Self.outcome(status: status, body: body)
        } catch {
            return .refused(.unreachable)
        }
    }

    /// "k7q-2mx " → "K7Q2MX": a code as the checker compares it.
    public static func normalized(code: String) -> String {
        code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The setup code in a `glassrail://connect?code=K7Q2MX` link.
    public static func setupCode(from url: URL) -> String? {
        guard url.scheme == "glassrail", url.host == "connect",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        let code = normalized(code: value)
        return code.isEmpty ? nil : code
    }

    public static func request(code: String, username: String, password: String) throws -> URLRequest {
        // NJ Transit's answer can take up to 20 seconds to reach the checker.
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": normalized(code: code),
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ])
        return request
    }

    public static func outcome(status: Int, body: Data) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .refused(.unreachable)
        }
        if status == 200, root["ok"] as? Bool == true { return .connected }
        return .refused((root["reason"] as? String).flatMap(Refusal.init(rawValue:)) ?? .unreachable)
    }

    public static let urlSession: @Sendable (URLRequest) async throws -> (Int, Data) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
