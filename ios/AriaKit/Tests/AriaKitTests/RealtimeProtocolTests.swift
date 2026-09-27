import XCTest
@testable import AriaKit

final class RealtimeProtocolTests: XCTestCase {
    func testSocketURL() {
        let hosted = SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "sb_publishable_x")
        XCTAssertEqual(RealtimeProtocol.socketURL(config: hosted).absoluteString,
                       "wss://abc.supabase.co/realtime/v1/websocket?apikey=sb_publishable_x&vsn=1.0.0")
        let local = SupabaseConfig(url: URL(string: "http://127.0.0.1:54321")!, anonKey: "k")
        XCTAssertEqual(RealtimeProtocol.socketURL(config: local).absoluteString, "ws://127.0.0.1:54321/realtime/v1/websocket?apikey=k&vsn=1.0.0")
    }

    func testJoinMessage() throws {
        let text = RealtimeProtocol.joinMessage(topic: "realtime:aria-x", userId: uuid(1), accessToken: "JWT", ref: "1")
        let message = try JSONValue.parse(text)
        XCTAssertEqual(message["event"], "phx_join")
        XCTAssertEqual(message["topic"], "realtime:aria-x")
        XCTAssertEqual(message["join_ref"], "1")
        XCTAssertEqual(message["payload"]?["access_token"], "JWT")
        let changes = message["payload"]?["config"]?["postgres_changes"]?.arrayValue ?? []
        XCTAssertEqual(changes.count, 5)
        XCTAssertEqual(changes[0], ["event": "*", "schema": "public", "table": "tasks", "filter": "user_id=eq.00000000-0000-4000-8000-000000000001"])
        XCTAssertEqual(changes[4], ["event": "DELETE", "schema": "public", "table": "events"])
    }

    func testParsesServerMessages() {
        XCTAssertEqual(RealtimeProtocol.parse(#"{"event":"phx_reply","topic":"realtime:aria-x","ref":"1","payload":{"status":"ok","response":{"postgres_changes":[]}}}"#), .joined)
        XCTAssertEqual(RealtimeProtocol.parse(#"{"event":"phx_reply","topic":"phoenix","ref":"2","payload":{"status":"ok","response":{}}}"#), .other)
        XCTAssertEqual(RealtimeProtocol.parse(#"{"event":"phx_reply","topic":"realtime:aria-x","ref":"1","payload":{"status":"error","response":{"reason":"Invalid JWT"}}}"#),
                       .joinFailed("Invalid JWT"))
        XCTAssertEqual(RealtimeProtocol.parse(#"{"event":"system","topic":"realtime:aria-x","payload":{"status":"error","message":"Unable to subscribe"}}"#),
                       .joinFailed("Unable to subscribe"))
        XCTAssertEqual(RealtimeProtocol.parse("""
        {"event":"postgres_changes","topic":"realtime:aria-x","ref":null,"payload":{"ids":[1],"data":{"schema":"public","table":"tasks",
         "commit_timestamp":"2026-09-27T12:00:00Z","type":"INSERT","record":{"id":"00000000-0000-4000-8000-000000000005","title":"x"},"errors":null}}}
        """), .change(RealtimeChange(table: "tasks", kind: .insert, recordId: uuid(5))))
        XCTAssertEqual(RealtimeProtocol.parse("""
        {"event":"postgres_changes","topic":"realtime:aria-x","payload":{"data":{"table":"events","type":"DELETE","old_record":{"id":"00000000-0000-4000-8000-000000000006"}}}}
        """), .change(RealtimeChange(table: "events", kind: .delete, recordId: uuid(6))))
        XCTAssertEqual(RealtimeProtocol.parse(#"{"event":"phx_close","topic":"realtime:aria-x","payload":{}}"#), .closed)
        XCTAssertEqual(RealtimeProtocol.parse("garbage"), .other)
        XCTAssertEqual(RealtimeProtocol.parse(#"{"event":"presence_state","payload":{}}"#), .other)
    }

    func testHeartbeatAndTokenMessages() throws {
        XCTAssertEqual(try JSONValue.parse(RealtimeProtocol.heartbeat(ref: "7")),
                       ["topic": "phoenix", "event": "heartbeat", "payload": [:], "ref": "7"])
        XCTAssertEqual(try JSONValue.parse(RealtimeProtocol.accessTokenMessage(topic: "t", accessToken: "JWT2", ref: "8"))["payload"],
                       ["access_token": "JWT2"])
    }
}
