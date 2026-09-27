import XCTest
@testable import AriaKit

final class SupabaseAuthTests: XCTestCase {
    let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: fakeJWT)
    let now = date("2026-09-27T12:00:00Z")

    func testSignInStoresSessionAndSendsAPIKey() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url.absoluteString, "https://demo.supabase.co/auth/v1/token?grant_type=password")
            return json(200, tokenBody(access: "A1", refresh: "R1", expiresAt: date("2026-09-27T13:00:00Z")))
        }
        let store = InMemorySessionStore()
        let fixedNow = now
        let auth = SupabaseAuth(config: config, transport: transport, store: store, now: { fixedNow })
        let session = try await auth.signIn(email: " alice@aria.test ", password: "pw")
        XCTAssertEqual(session.accessToken, "A1")
        XCTAssertEqual(session.user.email, "alice@aria.test")
        XCTAssertEqual(session.user.displayName, "Alice")
        XCTAssertEqual(store.loadSession(), session)
        let request = transport.requests[0]
        XCTAssertEqual(request.header("apikey"), fakeJWT)
        XCTAssertEqual(request.header("Authorization"), "Bearer \(fakeJWT)")
        XCTAssertEqual(bodyJSON(request), ["email": "alice@aria.test", "password": "pw"])
    }

    func testPublishableKeysAreNeverSentAsBearerTokens() async throws {
        let transport = MockTransport { _ in json(200, tokenBody(access: "A1", refresh: "R1", expiresAt: date("2026-09-27T13:00:00Z"))) }
        let auth = SupabaseAuth(config: SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "sb_publishable_x"),
                                transport: transport, store: InMemorySessionStore())
        _ = try await auth.signIn(email: "a@b.c", password: "pw")
        XCTAssertEqual(transport.requests[0].header("apikey"), "sb_publishable_x")
        XCTAssertNil(transport.requests[0].header("Authorization"))
    }

    func testSignInErrorsSurfaceGoTrueMessage() async {
        let transport = MockTransport { _ in
            json(400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#)
        }
        let auth = SupabaseAuth(config: config, transport: transport, store: InMemorySessionStore())
        do {
            _ = try await auth.signIn(email: "a@b.c", password: "nope")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AriaError, .server(status: 400, code: "invalid_credentials", message: "Invalid login credentials"))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Invalid login credentials")
        }
    }

    func testSignUpRequiringConfirmation() async {
        let transport = MockTransport { request in
            XCTAssertEqual(bodyJSON(request)?["data"]?["full_name"], "Alice")
            return json(200, #"{"id":"00000000-0000-4000-8000-000000000001","email":"a@b.c","confirmation_sent_at":"2026-09-27T12:00:00Z"}"#)
        }
        let auth = SupabaseAuth(config: config, transport: transport, store: InMemorySessionStore())
        do {
            _ = try await auth.signUp(email: "a@b.c", password: "password1", displayName: " Alice ")
            XCTFail("expected confirmation error")
        } catch {
            XCTAssertEqual(error as? AriaError, .emailConfirmationRequired)
        }
        let session = await auth.currentSession
        XCTAssertNil(session)
    }

    func testFreshTokenIsReturnedWithoutRefresh() async throws {
        let transport = MockTransport { _ in XCTFail("no request expected"); return json(500, "{}") }
        let store = InMemorySessionStore(AuthSession(accessToken: "A1", refreshToken: "R1", expiresAt: date("2026-09-27T13:00:00Z"),
                                                     user: AuthUser(id: uuid(1), email: nil)))
        let fixedNow = now
        let auth = SupabaseAuth(config: config, transport: transport, store: store, now: { fixedNow })
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "A1")
    }

    func testExpiringTokenIsRefreshedOnceForConcurrentCallers() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url.query, "grant_type=refresh_token")
            XCTAssertEqual(bodyJSON(request), ["refresh_token": "R1"])
            try await Task.sleep(nanoseconds: 50_000_000)
            return json(200, tokenBody(access: "A2", refresh: "R2", expiresAt: date("2026-09-27T13:30:00Z")))
        }
        let store = InMemorySessionStore(AuthSession(accessToken: "A1", refreshToken: "R1", expiresAt: date("2026-09-27T12:00:30Z"),
                                                     user: AuthUser(id: uuid(1), email: nil)))
        let fixedNow = now
        let auth = SupabaseAuth(config: config, transport: transport, store: store, now: { fixedNow })
        async let first = auth.accessToken()
        async let second = auth.accessToken()
        async let third = auth.accessToken()
        let tokens = try await [first, second, third]
        XCTAssertEqual(tokens, ["A2", "A2", "A2"])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(store.loadSession()?.refreshToken, "R2")
    }

    func testRejectedRefreshSignsOut() async {
        let transport = MockTransport { _ in json(400, #"{"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token"}"#) }
        let store = InMemorySessionStore(AuthSession(accessToken: "A1", refreshToken: "R1", expiresAt: date("2026-09-27T11:00:00Z"),
                                                     user: AuthUser(id: uuid(1), email: nil)))
        let fixedNow = now
        let auth = SupabaseAuth(config: config, transport: transport, store: store, now: { fixedNow })
        do {
            _ = try await auth.accessToken()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AriaError, .notAuthenticated)
        }
        XCTAssertNil(store.loadSession())
    }

    func testNetworkFailureDuringRefreshKeepsTheSession() async {
        let transport = MockTransport { _ in throw AriaError.network("offline") }
        let session = AuthSession(accessToken: "A1", refreshToken: "R1", expiresAt: date("2026-09-27T11:00:00Z"),
                                  user: AuthUser(id: uuid(1), email: nil))
        let store = InMemorySessionStore(session)
        let fixedNow = now
        let auth = SupabaseAuth(config: config, transport: transport, store: store, now: { fixedNow })
        do {
            _ = try await auth.accessToken()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AriaError, .network("offline"))
        }
        XCTAssertEqual(store.loadSession(), session)
    }

    func testPicksUpTokensRotatedByAnotherProcess() async throws {
        let transport = MockTransport { _ in XCTFail("no request expected"); return json(500, "{}") }
        let store = InMemorySessionStore(AuthSession(accessToken: "A1", refreshToken: "R1", expiresAt: date("2026-09-27T12:00:30Z"),
                                                     user: AuthUser(id: uuid(1), email: nil)))
        let fixedNow = now
        let auth = SupabaseAuth(config: config, transport: transport, store: store, now: { fixedNow })
        // The widget refreshed while the app was suspended.
        store.saveSession(AuthSession(accessToken: "A2", refreshToken: "R2", expiresAt: date("2026-09-27T13:00:00Z"),
                                      user: AuthUser(id: uuid(1), email: nil)))
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "A2")
        // …and a sign-out elsewhere is honoured too.
        store.saveSession(nil)
        let user = await auth.currentUser
        XCTAssertNil(user)
    }

    func testSignOutRevokesAndClears() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url.path, "/auth/v1/logout")
            XCTAssertEqual(request.header("Authorization"), "Bearer A1")
            return HTTPResponse(status: 204)
        }
        let store = InMemorySessionStore(AuthSession(accessToken: "A1", refreshToken: "R1", expiresAt: date("2026-09-27T13:00:00Z"),
                                                     user: AuthUser(id: uuid(1), email: nil)))
        let auth = SupabaseAuth(config: config, transport: transport, store: store)
        await auth.signOut()
        XCTAssertNil(store.loadSession())
        XCTAssertEqual(transport.requests.count, 1)
    }
}

final class SupabaseClientTests: XCTestCase {
    let config = SupabaseConfig(url: URL(string: "https://demo.supabase.co")!, anonKey: "sb_publishable_x")

    func signedInStore(expiresAt: Date = Date().addingTimeInterval(3600)) -> InMemorySessionStore {
        InMemorySessionStore(AuthSession(accessToken: "USER_JWT", refreshToken: "R1", expiresAt: expiresAt,
                                         user: AuthUser(id: uuid(1), email: "alice@aria.test")))
    }

    func testCreateTaskPostsRepresentation() async throws {
        let transport = MockTransport { request in
            json(201, """
            [{"id":"00000000-0000-4000-8000-000000000009","user_id":"00000000-0000-4000-8000-000000000001","title":"Buy milk",
              "notes":null,"due_at":null,"completed":false,"completed_at":null,"priority":0,"source":"user",
              "created_at":"2026-09-27T12:00:00+00:00","updated_at":"2026-09-27T12:00:00+00:00"}]
            """)
        }
        let client = SupabaseClient(config: config, sessionStore: signedInStore(), transport: transport)
        let task = try await client.createTask(NewTask(id: uuid(9), title: "Buy milk"))
        XCTAssertEqual(task.id, uuid(9))
        let request = transport.requests[0]
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://demo.supabase.co/rest/v1/tasks")
        XCTAssertEqual(request.header("apikey"), "sb_publishable_x")
        XCTAssertEqual(request.header("Authorization"), "Bearer USER_JWT")
        XCTAssertEqual(request.header("Prefer"), "return=representation")
        XCTAssertEqual(bodyJSON(request)?["title"], "Buy milk")
    }

    func testUpdateAndDeleteTargetOneRow() async throws {
        let transport = MockTransport { request in
            request.method == "DELETE" ? json(200, "[]") : json(200, "[]")
        }
        let client = SupabaseClient(config: config, sessionStore: signedInStore(), transport: transport)
        let updated = try await client.setTaskCompleted(id: uuid(5), completed: true)
        XCTAssertNil(updated, "no row matched")
        let deleted = try await client.deleteEvent(id: uuid(6))
        XCTAssertNil(deleted)
        XCTAssertEqual(transport.requests[0].method, "PATCH")
        XCTAssertEqual(queryItems(transport.requests[0])["id"], ["eq.00000000-0000-4000-8000-000000000005"])
        XCTAssertEqual(bodyJSON(transport.requests[0]), ["completed": true])
        XCTAssertEqual(transport.requests[1].url.path, "/rest/v1/events")
        XCTAssertEqual(queryItems(transport.requests[1])["id"], ["eq.00000000-0000-4000-8000-000000000006"])
    }

    func testEventWindowQueryIsPaddedAndFiltered() async throws {
        let transport = MockTransport { _ in
            json(200, """
            [{"id":"00000000-0000-4000-8000-000000000001","title":"Yesterday all day","start_at":"2026-09-26T00:00:00+00:00",
              "end_at":"2026-09-27T00:00:00+00:00","all_day":true,"source":"user"},
             {"id":"00000000-0000-4000-8000-000000000002","title":"Today all day","start_at":"2026-09-27T00:00:00+00:00",
              "end_at":"2026-09-28T00:00:00+00:00","all_day":true,"source":"user"},
             {"id":"00000000-0000-4000-8000-000000000003","title":"Lunch","start_at":"2026-09-27T16:00:00+00:00",
              "end_at":"2026-09-27T17:00:00+00:00","all_day":false,"source":"ai"}]
            """)
        }
        let client = SupabaseClient(config: config, sessionStore: signedInStore(), transport: transport)
        let tokyo = calendar(TimeZone(identifier: "Asia/Tokyo")!)
        let day = DayKey("2026-09-27")!.interval(in: tokyo)
        let events = try await client.fetchEvents(overlapping: day, calendar: tokyo)
        XCTAssertEqual(events.map(\.title), ["Today all day"], "Lunch is on 28 Sep in Tokyo; yesterday's all-day event is excluded")
        let params = queryItems(transport.requests[0])
        XCTAssertEqual(params["start_at"], ["lt.2026-09-28T15:00:00.000Z"])
        XCTAssertEqual(params["or"], ["(end_at.gt.2026-09-25T15:00:00.000Z,start_at.gte.2026-09-25T15:00:00.000Z)"])
    }

    func testExpiredJWTIsRefreshedAndRetriedOnce() async throws {
        let calls = Box(0)
        let transport = MockTransport { request in
            if request.url.path.hasPrefix("/auth/v1/token") {
                return json(200, tokenBody(access: "NEW_JWT", refresh: "R2", expiresAt: Date().addingTimeInterval(3600)))
            }
            calls.mutate { $0 += 1 }
            if request.header("Authorization") == "Bearer USER_JWT" {
                return json(401, #"{"code":"PGRST303","message":"JWT expired"}"#)
            }
            return json(200, "[]")
        }
        let client = SupabaseClient(config: config, sessionStore: signedInStore(), transport: transport)
        let tasks = try await client.fetchTasks(.allOpen)
        XCTAssertEqual(tasks, [])
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(transport.requests.last?.header("Authorization"), "Bearer NEW_JWT")
    }

    func testServerErrorsCarryPostgRESTMessage() async {
        let transport = MockTransport { _ in json(403, #"{"code":"42501","details":null,"hint":null,"message":"permission denied for table tasks"}"#) }
        let client = SupabaseClient(config: config, sessionStore: signedInStore(), transport: transport)
        do {
            _ = try await client.fetchTasks(.allOpen)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AriaError, .server(status: 403, code: "42501", message: "permission denied for table tasks"))
        }
    }

    func testRequestsFailFastWhenSignedOut() async {
        let transport = MockTransport { _ in XCTFail("no request expected"); return json(500, "{}") }
        let client = SupabaseClient(config: config, sessionStore: InMemorySessionStore(), transport: transport)
        do {
            _ = try await client.fetchTasks(.allOpen)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AriaError, .notAuthenticated)
        }
    }

    func testUpsertByCalendarIdUsesOnConflictAndNoId() async throws {
        let transport = MockTransport { _ in
            json(201, """
            [{"id":"00000000-0000-4000-8000-000000000004","title":"Dentist","start_at":"2026-10-01T13:00:00+00:00",
              "end_at":"2026-10-01T14:00:00+00:00","all_day":false,"ios_calendar_event_id":"EK-1","source":"user"}]
            """)
        }
        let client = SupabaseClient(config: config, sessionStore: signedInStore(), transport: transport)
        _ = try await client.upsertEventByCalendarId(NewEvent(id: uuid(99), title: "Dentist", startAt: date("2026-10-01T13:00:00Z"),
                                                              endAt: date("2026-10-01T14:00:00Z"), iosCalendarEventId: "EK-1"))
        let request = transport.requests[0]
        XCTAssertEqual(queryItems(request)["on_conflict"], ["user_id,ios_calendar_event_id"])
        XCTAssertEqual(request.header("Prefer"), "resolution=merge-duplicates,return=representation")
        XCTAssertNil(bodyJSON(request)?["id"])
        XCTAssertEqual(bodyJSON(request)?["user_id"], "00000000-0000-4000-8000-000000000001")
    }

    func testCalendarIdLookupQuotesValues() async throws {
        let transport = MockTransport { _ in json(200, "[]") }
        let client = SupabaseClient(config: config, sessionStore: signedInStore(), transport: transport)
        _ = try await client.fetchEventRows(calendarIds: ["A,1", "B(2)"])
        XCTAssertEqual(queryItems(transport.requests[0])["ios_calendar_event_id"], [#"in.("A,1","B(2)")"#])
    }
}
