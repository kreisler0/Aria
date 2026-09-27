import Foundation

/// Connection details for a Supabase project. The anon (publishable) key is public by
/// design — Row-Level Security is what protects the data.
public struct SupabaseConfig: Codable, Hashable, Sendable {
    public var url: URL
    public var anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// Validates user input from the setup screen. Plain `http` is only accepted for
    /// local development hosts.
    public init?(urlString: String, anonKey: String) {
        var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        let key = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return nil }
        let isLocal = ["localhost", "127.0.0.1", "::1", "10.0.2.2"].contains(host.lowercased()) || host.hasSuffix(".local")
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        self.init(url: url, anonKey: key)
    }

    public var restURL: URL { url.appendingPathComponent("rest/v1") }
    public var authURL: URL { url.appendingPathComponent("auth/v1") }

    /// Legacy anon keys are JWTs (`eyJ…`); the newer `sb_publishable_…` keys are not and
    /// must only ever travel in the `apikey` header.
    public var anonKeyIsJWT: Bool { anonKey.hasPrefix("eyJ") }
}

public struct AuthUser: Codable, Hashable, Sendable {
    public var id: UUID
    public var email: String?
    public var displayName: String?

    public init(id: UUID, email: String?, displayName: String? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }
}

public struct AuthSession: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var user: AuthUser

    public init(accessToken: String, refreshToken: String, expiresAt: Date, user: AuthUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
    }

    public func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= interval
    }
}

/// Persists the auth session. The app and the widget extension share one store (the
/// Keychain, via the App Group access group) so both stay signed in.
public protocol SessionStore: Sendable {
    func loadSession() -> AuthSession?
    func saveSession(_ session: AuthSession?)
}

public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    public init(_ session: AuthSession? = nil) {
        self.session = session
    }

    public func loadSession() -> AuthSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func saveSession(_ session: AuthSession?) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }
}

/// GoTrue's token response.
struct TokenResponse: Decodable {
    struct User: Decodable {
        var id: UUID
        var email: String?
        var userMetadata: [String: JSONValue]?

        enum CodingKeys: String, CodingKey {
            case id, email
            case userMetadata = "user_metadata"
        }
    }

    var accessToken: String?
    var refreshToken: String?
    var expiresIn: Double?
    var expiresAt: Double?
    var user: User?
    // A sign-up that still needs email confirmation returns the bare user object.
    var id: UUID?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user, id
    }

    func session(now: Date) -> AuthSession? {
        guard let accessToken, let refreshToken, let user else { return nil }
        let expiry: Date
        if let expiresAt {
            expiry = Date(timeIntervalSince1970: expiresAt)
        } else {
            expiry = now.addingTimeInterval(expiresIn ?? 3600)
        }
        let name = user.userMetadata?["full_name"]?.stringValue ?? user.userMetadata?["name"]?.stringValue
        return AuthSession(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiry,
                           user: AuthUser(id: user.id, email: user.email, displayName: name))
    }
}

/// Supabase Auth (GoTrue) over plain HTTP: email/password sign-in and sign-up, token
/// refresh with coalescing, and sign-out.
public actor SupabaseAuth {
    public nonisolated let config: SupabaseConfig
    private let transport: HTTPTransport
    private let store: SessionStore
    private let now: @Sendable () -> Date
    private var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?

    public init(config: SupabaseConfig, transport: HTTPTransport, store: SessionStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.transport = transport
        self.store = store
        self.now = now
        self.session = store.loadSession()
    }

    public var currentSession: AuthSession? {
        adoptNewerStoredSession()
        return session
    }

    public var currentUser: AuthUser? { currentSession?.user }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        let body: JSONValue = ["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)), "password": .string(password)]
        let response = try await post(path: "token", query: "grant_type=password", body: body)
        return try adopt(response)
    }

    /// Creates an account. Throws `AriaError.emailConfirmationRequired` when the project
    /// requires confirming the address before the first sign-in.
    public func signUp(email: String, password: String, displayName: String? = nil) async throws -> AuthSession {
        var body: [String: JSONValue] = [
            "email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)),
            "password": .string(password),
        ]
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            body["data"] = ["full_name": .string(displayName.trimmingCharacters(in: .whitespaces))]
        }
        let response = try await post(path: "signup", query: nil, body: .object(body))
        let token = try AriaJSON.makeDecoder().decode(TokenResponse.self, from: response.body)
        guard token.session(now: now()) != nil else { throw AriaError.emailConfirmationRequired }
        return try adopt(response)
    }

    /// Revokes the refresh token server-side (best effort) and forgets the session.
    public func signOut() async {
        if let session {
            var headers = baseHeaders()
            headers["Authorization"] = "Bearer \(session.accessToken)"
            let request = HTTPRequest(method: "POST", url: config.authURL.appendingPathComponent("logout"), headers: headers)
            _ = try? await transport.send(request)
        }
        session = nil
        store.saveSession(nil)
    }

    /// A non-expired access token, refreshing it first if it expires within a minute.
    public func accessToken() async throws -> String {
        adoptNewerStoredSession()
        guard let current = session else { throw AriaError.notAuthenticated }
        if !current.expires(within: 60, now: now()) {
            return current.accessToken
        }
        return try await refreshSession().accessToken
    }

    /// Exchanges the refresh token for a new session. Concurrent callers share one request.
    @discardableResult
    public func refreshSession() async throws -> AuthSession {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let current = session else { throw AriaError.notAuthenticated }
        let task = Task { try await self.performRefresh(using: current.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch AriaError.server(let status, _, _) where (400..<500).contains(status) {
            // Another process (app ↔ widget) may have rotated the token already.
            if let stored = store.loadSession(), stored.refreshToken != current.refreshToken,
               !stored.expires(within: 60, now: now()) {
                session = stored
                return stored
            }
            session = nil
            store.saveSession(nil)
            throw AriaError.notAuthenticated
        }
    }

    private func performRefresh(using refreshToken: String) async throws -> AuthSession {
        let response = try await post(path: "token", query: "grant_type=refresh_token",
                                      body: ["refresh_token": .string(refreshToken)])
        return try adopt(response)
    }

    private func adopt(_ response: HTTPResponse) throws -> AuthSession {
        let token: TokenResponse
        do {
            token = try AriaJSON.makeDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw AriaError.decoding("auth response: \(error)")
        }
        guard let newSession = token.session(now: now()) else {
            throw AriaError.decoding("auth response did not contain a session")
        }
        session = newSession
        store.saveSession(newSession)
        return newSession
    }

    /// The store is shared between processes (app ↔ widget), so it is the source of
    /// truth: pick up tokens rotated elsewhere, and a sign-out made elsewhere.
    private func adoptNewerStoredSession() {
        guard let stored = store.loadSession() else {
            session = nil
            return
        }
        guard stored != session else { return }
        if let current = session, current.user.id == stored.user.id, stored.expiresAt < current.expiresAt {
            return
        }
        session = stored
    }

    private func baseHeaders() -> [String: String] {
        var headers = ["apikey": config.anonKey, "Content-Type": "application/json", "Accept": "application/json"]
        if config.anonKeyIsJWT {
            headers["Authorization"] = "Bearer \(config.anonKey)"
        }
        return headers
    }

    private func post(path: String, query: String?, body: JSONValue) async throws -> HTTPResponse {
        var urlString = config.authURL.appendingPathComponent(path).absoluteString
        if let query { urlString += "?" + query }
        guard let url = URL(string: urlString) else { throw AriaError.notConfigured }
        let data = try JSONEncoder().encode(body)
        let response = try await transport.send(HTTPRequest(method: "POST", url: url, headers: baseHeaders(), body: data))
        guard response.isSuccess else {
            let parsed = AriaError.message(from: response.body, fallbackStatus: response.status)
            throw AriaError.server(status: response.status, code: parsed.code, message: parsed.message)
        }
        return response
    }
}
