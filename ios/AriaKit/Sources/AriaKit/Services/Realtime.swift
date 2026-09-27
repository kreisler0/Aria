import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A row change pushed by Supabase Realtime.
public struct RealtimeChange: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case insert = "INSERT"
        case update = "UPDATE"
        case delete = "DELETE"
    }

    public var table: String
    public var kind: Kind
    /// `record.id`, or `old_record.id` for deletes.
    public var recordId: UUID?

    public init(table: String, kind: Kind, recordId: UUID?) {
        self.table = table
        self.kind = kind
        self.recordId = recordId
    }
}

public enum RealtimeMessage: Hashable, Sendable {
    case joined
    case joinFailed(String)
    case change(RealtimeChange)
    case closed
    case other
}

/// Supabase Realtime speaks the Phoenix channel protocol (JSON, `vsn=1.0.0`). Aria
/// subscribes to `postgres_changes` on its tables and simply refreshes when something
/// changes, so another device's edits (or the AI's, from Windows) show up immediately.
public enum RealtimeProtocol {
    public static let tables = ["tasks", "events", "planner_days"]

    public static func socketURL(config: SupabaseConfig) -> URL {
        var components = URLComponents(url: config.url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        components.path = components.path + "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: config.anonKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        return components.url!
    }

    public static func topic(for userId: UUID) -> String { "realtime:aria-\(userId.lowercasedString)" }

    /// Row changes for the user's rows, plus unfiltered deletes (Postgres can't filter
    /// deletes; they only carry the primary key, so the app ignores ids it doesn't know).
    public static func joinMessage(topic: String, userId: UUID, accessToken: String, ref: String) -> String {
        var changes: [JSONValue] = tables.map { table in
            ["event": "*", "schema": "public", "table": .string(table), "filter": .string("user_id=eq.\(userId.lowercasedString)")]
        }
        changes += ["tasks", "events"].map { table in ["event": "DELETE", "schema": "public", "table": .string(table)] }
        let payload: JSONValue = [
            "config": [
                "broadcast": ["ack": false, "self": false],
                "presence": ["key": ""],
                "postgres_changes": .array(changes),
                "private": false,
            ],
            "access_token": .string(accessToken),
        ]
        return envelope(topic: topic, event: "phx_join", payload: payload, ref: ref, joinRef: ref)
    }

    public static func heartbeat(ref: String) -> String {
        envelope(topic: "phoenix", event: "heartbeat", payload: [:], ref: ref, joinRef: nil)
    }

    public static func accessTokenMessage(topic: String, accessToken: String, ref: String) -> String {
        envelope(topic: topic, event: "access_token", payload: ["access_token": .string(accessToken)], ref: ref, joinRef: nil)
    }

    public static func parse(_ text: String) -> RealtimeMessage {
        guard let message = try? JSONValue.parse(text), let event = message["event"]?.stringValue else { return .other }
        let payload = message["payload"]
        switch event {
        case "phx_reply":
            guard message["topic"]?.stringValue != "phoenix" else { return .other } // heartbeat ack
            if payload?["status"]?.stringValue == "ok" { return .joined }
            let reason = payload?["response"]?["reason"]?.stringValue ?? payload?["response"]?.jsonString() ?? "join rejected"
            return .joinFailed(reason)
        case "system":
            if payload?["status"]?.stringValue == "error" {
                return .joinFailed(payload?["message"]?.stringValue ?? "realtime error")
            }
            return .other
        case "postgres_changes":
            guard let data = payload?["data"], let table = data["table"]?.stringValue,
                  let kind = data["type"]?.stringValue.flatMap(RealtimeChange.Kind.init(rawValue:)) else { return .other }
            let id = (data["record"]?["id"] ?? data["old_record"]?["id"])?.stringValue.flatMap(UUID.init(uuidString:))
            return .change(RealtimeChange(table: table, kind: kind, recordId: id))
        case "phx_error", "phx_close":
            return .closed
        default:
            return .other
        }
    }

    private static func envelope(topic: String, event: String, payload: JSONValue, ref: String, joinRef: String?) -> String {
        var object: [String: JSONValue] = [
            "topic": .string(topic), "event": .string(event), "payload": payload, "ref": .string(ref),
        ]
        if let joinRef { object["join_ref"] = .string(joinRef) }
        return JSONValue.object(object).jsonString()
    }
}

#if canImport(Darwin)
/// Keeps a Realtime websocket open while the app is in the foreground and reports row
/// changes. Reconnects with backoff and forwards refreshed access tokens.
public final class RealtimeClient: @unchecked Sendable {
    private let config: SupabaseConfig
    private let auth: SupabaseAuth
    private let onChange: @Sendable (RealtimeChange) -> Void
    private let lock = NSLock()
    private var loop: Task<Void, Never>?

    public init(config: SupabaseConfig, auth: SupabaseAuth, onChange: @escaping @Sendable (RealtimeChange) -> Void) {
        self.config = config
        self.auth = auth
        self.onChange = onChange
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        loop?.cancel()
        loop = nil
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await connectOnce()
                failures = 0
            } catch {
                failures += 1
            }
            guard !Task.isCancelled else { return }
            let delay = min(60.0, pow(2.0, Double(min(failures, 6))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func connectOnce() async throws {
        guard let user = await auth.currentUser else { throw AriaError.notAuthenticated }
        let token = try await auth.accessToken()
        let socket = URLSession.shared.webSocketTask(with: RealtimeProtocol.socketURL(config: config))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let topic = RealtimeProtocol.topic(for: user.id)
        try await socket.send(.string(RealtimeProtocol.joinMessage(topic: topic, userId: user.id, accessToken: token, ref: "1")))

        let auth = self.auth
        let heartbeat = Task {
            var counter = 1
            var currentToken = token
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                counter += 1
                try await socket.send(.string(RealtimeProtocol.heartbeat(ref: "\(counter)")))
                if let fresh = try? await auth.accessToken(), fresh != currentToken {
                    counter += 1
                    currentToken = fresh
                    try await socket.send(.string(RealtimeProtocol.accessTokenMessage(topic: topic, accessToken: fresh,
                                                                                      ref: "\(counter)")))
                }
            }
        }
        defer { heartbeat.cancel() }

        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message else { continue }
            switch RealtimeProtocol.parse(text) {
            case .change(let change):
                onChange(change)
            case .joinFailed(let reason):
                throw AriaError.server(status: 0, code: "realtime", message: reason)
            case .closed:
                return
            case .joined, .other:
                break
            }
        }
    }
}
#endif
