import XCTest
@testable import GlassRailKit

/// Connecting the track checker to NJ Transit from Settings: what the app
/// sends penn-connect, and what it makes of the answer.
final class PennConnectTests: XCTestCase {
    func testSetupCodesAreReadTheWayTheCheckerReadsThem() {
        XCTAssertEqual(PennConnect.normalized(code: " k7q-2mx "), "K7Q2MX")
        XCTAssertEqual(PennConnect.normalized(code: "K7Q 2MX"), "K7Q2MX")
        XCTAssertEqual(PennConnect.normalized(code: "é-ü"), "")
    }

    func testASetupLinkCarriesItsCode() throws {
        XCTAssertEqual(PennConnect.setupCode(from: try XCTUnwrap(URL(string: "glassrail://connect?code=k7q-2mx"))), "K7Q2MX")
        XCTAssertNil(PennConnect.setupCode(from: try XCTUnwrap(URL(string: "glassrail://board"))))
        XCTAssertNil(PennConnect.setupCode(from: try XCTUnwrap(URL(string: "glassrail://connect"))))
        XCTAssertNil(PennConnect.setupCode(from: try XCTUnwrap(URL(string: "glassrail://connect?code=--"))))
        XCTAssertNil(PennConnect.setupCode(from: try XCTUnwrap(URL(string: "https://example.com/connect?code=K7Q2MX"))))
    }

    func testTheCodeAndLoginGoOnceAsJSON() throws {
        let request = try PennConnect.request(code: "k7q-2mx", username: "  rider@example.com ", password: " pass word ")
        XCTAssertEqual(request.url, PennConnect.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        // The password goes exactly as typed; spaces can be part of it.
        XCTAssertEqual(body, ["code": "K7Q2MX", "username": "rider@example.com", "password": " pass word "])
    }

    func testReadsWhatTheCheckerAnswers() {
        func outcome(_ status: Int, _ json: String) -> PennConnect.Outcome {
            PennConnect.outcome(status: status, body: Data(json.utf8))
        }
        XCTAssertEqual(outcome(200, #"{"ok": true}"#), .connected)
        XCTAssertEqual(outcome(200, #"{"ok": false, "reason": "login"}"#), .refused(.login))
        XCTAssertEqual(outcome(200, #"{"ok": false, "reason": "code"}"#), .refused(.code))
        XCTAssertEqual(outcome(200, #"{"ok": false, "reason": "code-used"}"#), .refused(.codeUsed))
        XCTAssertEqual(outcome(200, #"{"ok": false, "reason": "code-expired"}"#), .refused(.codeExpired))
        XCTAssertEqual(outcome(200, #"{"ok": false, "reason": "code-locked"}"#), .refused(.codeLocked))
        XCTAssertEqual(outcome(200, #"{"ok": false, "reason": "busy"}"#), .refused(.busy))
        XCTAssertEqual(outcome(502, #"{"ok": false, "reason": "unreachable"}"#), .refused(.unreachable))
        // Anything else is the checker's trouble, never a connection.
        XCTAssertEqual(outcome(200, #"{"ok": false, "reason": "something new"}"#), .refused(.unreachable))
        XCTAssertEqual(outcome(502, "<html>Bad gateway</html>"), .refused(.unreachable))
        XCTAssertEqual(outcome(500, #"{"ok": true}"#), .refused(.unreachable))
    }

    func testAFailedRequestReadsAsUnreachable() async {
        struct Offline: Error {}
        let offline = PennConnect(send: { _ in throw Offline() })
        let failed = await offline.connect(code: "K7Q2MX", username: "rider", password: "secret")
        XCTAssertEqual(failed, .refused(.unreachable))

        let online = PennConnect(send: { _ in (200, Data(#"{"ok": true}"#.utf8)) })
        let connected = await online.connect(code: "K7Q2MX", username: "rider", password: "secret")
        XCTAssertEqual(connected, .connected)
    }

    func testEveryRefusalSaysSomethingOfItsOwn() {
        let all: [PennConnect.Refusal] = [.code, .codeUsed, .codeExpired, .codeLocked, .login, .busy, .unreachable]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        XCTAssertEqual(PennConnect.Refusal.login.message, "NJ Transit didn't accept that username and password.")
    }
}
