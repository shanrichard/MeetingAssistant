import Foundation
import MeetingCore

private let base = Date(timeIntervalSince1970: 1_790_000_000)
private func event(_ id: String, start: Double, end: Double, title: String? = nil, allDay: Bool = false,
                   status: String = "confirmed", type: String = "default", response: String? = "accepted") -> CalendarEvent {
    CalendarEvent(id: id, title: title ?? id, start: base.addingTimeInterval(start * 60), end: base.addingTimeInterval(end * 60),
                  isAllDay: allDay, status: status, eventType: type,
                  attendees: response.map { [CalendarPerson(email: "me@example.com", response: $0, isSelf: true)] } ?? [])
}

func checkGoogleEventParsing() throws {
    let shanghai = try require(TimeZone(identifier: "Asia/Shanghai"))
    let timed = try require(CalendarEvent.google([
        "id": "weekly_20261005T080000Z", "iCalUID": "weekly@google.com", "status": "confirmed", "summary": " 产品周会 ",
        "recurringEventId": "weekly", "originalStartTime": ["dateTime": "2026-10-05T16:00:00+08:00"],
        "start": ["dateTime": "2026-10-05T16:30:00+08:00"], "end": ["dateTime": "2026-10-05T17:00:00.000+08:00"],
        "organizer": ["email": "lead@example.com", "displayName": "Lead"],
        "attendees": [["email": "me@example.com", "self": true, "responseStatus": "accepted"],
                      ["email": "room@resource.calendar.google.com", "resource": true, "responseStatus": "accepted"],
                      ["email": "lead@example.com", "organizer": true, "responseStatus": "accepted", "displayName": "Lead"]],
        "hangoutLink": "https://meet.google.com/abc-defg-hij",
        "description": "Agenda https://zoom.us/j/123"
    ], timeZone: shanghai))
    expect(timed.id == "weekly_20261005T080000Z" && timed.recurringEventID == "weekly" && timed.iCalUID == "weekly@google.com")
    expect(timed.start == GoogleTimeFixture.date("2026-10-05T08:30:00Z"))
    expect(timed.end == GoogleTimeFixture.date("2026-10-05T09:00:00Z"))
    expect(timed.originalStart == GoogleTimeFixture.date("2026-10-05T08:00:00Z")) // Rescheduled occurrence keeps its original slot.
    expect(!timed.isAllDay && timed.title == " 产品周会 " && timed.displayTitle == "产品周会")
    expect(timed.attendees.count == 2) // The meeting room is not a person.
    expect(timed.selfResponse == "accepted" && timed.organizer?.isOrganizer == true && timed.organizer?.displayName == "Lead")
    expect(timed.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij") // Conference link wins over text.

    let allDay = try require(CalendarEvent.google(["id": "holiday", "summary": "Holiday",
        "start": ["date": "2026-10-05"], "end": ["date": "2026-10-06"]], timeZone: shanghai))
    expect(allDay.isAllDay && allDay.start == GoogleTimeFixture.date("2026-10-04T16:00:00Z"))

    let zoom = try require(CalendarEvent.google(["id": "zoom", "start": ["dateTime": "2026-10-05T10:00:00Z"],
        "end": ["dateTime": "2026-10-05T11:00:00Z"], "location": "http://zoom.us/j/1 Room 3",
        "description": "Docs: https://example.com/doc\nJoin: https://acme.zoom.us/j/987?pwd=x"]))
    expect(zoom.joinURL?.host == "acme.zoom.us") // Plain-http and non-meeting links are ignored.
    expect(zoom.title.isEmpty && zoom.displayTitle == "（无标题日程）")
    let conference = try require(CalendarEvent.google(["id": "teams", "start": ["dateTime": "2026-10-05T10:00:00Z"],
        "end": ["dateTime": "2026-10-05T11:00:00Z"],
        "conferenceData": ["entryPoints": [["entryPointType": "phone", "uri": "tel:+1"], ["entryPointType": "video", "uri": "https://teams.microsoft.com/l/meetup"]]]]))
    expect(conference.joinURL?.host == "teams.microsoft.com")
    let plain = try require(CalendarEvent.google(["id": "plain", "start": ["dateTime": "2026-10-05T10:00:00Z"],
        "end": ["dateTime": "2026-10-05T11:00:00Z"], "description": "https://evil.example/zoom.us"]))
    expect(plain.joinURL == nil)
    expect(CalendarEvent.google(["id": "broken", "start": [:], "end": ["dateTime": "2026-10-05T11:00:00Z"]]) == nil)
}

enum GoogleTimeFixture {
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
}

func checkCalendarSchedule() {
    let events = [
        event("soon", start: 9, end: 40), event("later", start: 11, end: 40), event("ongoing", start: -30, end: 30),
        event("ended", start: -60, end: 0), event("allDay", start: -600, end: 840, allDay: true),
        event("declined", start: 0, end: 30, response: "declined"), event("cancelled", start: 0, end: 30, status: "cancelled"),
        event("focus", start: 0, end: 30, type: "focusTime"), event("ooo", start: 0, end: 30, type: "outOfOffice"),
        event("empty", start: 5, end: 5), event("tentative", start: 5, end: 30, response: "tentative"),
        event("noInvite", start: 2, end: 30, response: nil), event("overlap", start: 9, end: 40)
    ]
    let startable = CalendarSchedule.startable(events, at: base).map(\.id)
    expect(startable == ["ongoing", "noInvite", "tentative", "overlap", "soon"])
    expect(CalendarSchedule.lead == 600)
    expect(CalendarSchedule.startable(events, at: base.addingTimeInterval(60)).contains { $0.id == "later" }) // Exactly ten minutes ahead.
    expect(CalendarSchedule.startable(events, at: base.addingTimeInterval(30 * 60)).map(\.id) == ["overlap", "soon", "later"])
    // Late arrivals still see the meeting until it ends; afterwards it no longer leads.
    expect(CalendarSchedule.startable([event("late", start: -50, end: 10)], at: base).count == 1)
    expect(CalendarSchedule.startable([event("over", start: -50, end: 0)], at: base).isEmpty)

    let recorded: Set<CalendarEventKey> = [CalendarEventKey(account: "ME@example.com", calendarID: "primary", eventID: "ongoing")]
    let prominent = CalendarSchedule.prominent(events, at: base, account: "me@EXAMPLE.com", recorded: recorded).map(\.id)
    expect(prominent == ["noInvite", "tentative", "overlap", "soon"])
    expect(CalendarSchedule.prominent(events, at: base, account: "other@example.com", recorded: recorded).count == 5)

    // The agenda lists every meeting that has not ended, however far ahead within the synced range.
    let tomorrow = event("tomorrow", start: 24 * 60, end: 25 * 60)
    expect(CalendarSchedule.upcoming(events + [tomorrow], at: base).map(\.id)
           == ["ongoing", "noInvite", "tentative", "overlap", "soon", "later", "tomorrow"])

    var previous = event("weekly_1", start: -7 * 24 * 60, end: -7 * 24 * 60 + 30); previous.recurringEventID = "weekly"
    var current = event("weekly_2", start: 30, end: 60); current.recurringEventID = "weekly"
    var older = Meeting(calendar: CalendarLink(event: previous, account: "me@example.com"))
    older.createdAt = base.addingTimeInterval(-7 * 24 * 3600)
    let sameOccurrence = Meeting(calendar: CalendarLink(event: current, account: "me@example.com"))
    let otherAccount = Meeting(calendar: CalendarLink(event: previous, account: "other@example.com"))
    let series = CalendarSchedule.seriesRecords([sameOccurrence, older, otherAccount, Meeting()], for: current, account: "ME@example.com")
    expect(series.map(\.id) == [older.id])
    expect(CalendarSchedule.seriesRecords([older], for: tomorrow, account: "me@example.com").isEmpty)

    let linkable = CalendarSchedule.linkable(events, around: base.addingTimeInterval(8 * 60)).map(\.id)
    expect(linkable.prefix(2) == ["overlap", "soon"])
    expect(!linkable.contains("allDay") && !linkable.contains("declined") && linkable.contains("ended"))
}

func checkCalendarLinkOnMeeting() throws {
    let account = "Me@Example.com"
    var weekly = event("weekly_1", start: 0, end: 30, title: "  产品周会")
    weekly.recurringEventID = "weekly"; weekly.originalStart = base; weekly.iCalUID = "weekly@google.com"
    weekly.organizer = CalendarPerson(email: "lead@example.com", isOrganizer: true)
    let link = CalendarLink(event: weekly, account: account, linkedAt: base)
    expect(link.account == "me@example.com" && link.title == "产品周会" && link.recurringEventID == "weekly")
    expect(link.key == CalendarEventKey(account: "ME@example.com", calendarID: "primary", eventID: "weekly_1"))

    var linked = Meeting(calendar: link)
    expect(linked.title == "产品周会" && linked.titleFollowsCalendar && linked.calendar == link)
    linked.liveSegments = [TranscriptSegment(id: "s1", source: .system, start: 0, end: 2, text: "Ship Friday")]
    linked.applySummary(MeetingSummary(title: "Release timing", overview: [], decisions: [], actions: [], questions: []))
    expect(linked.title == "产品周会" && linked.titleFollowsCalendar) // A summary never replaces the calendar name.
    expect(linked.markdown().contains("日程：产品周会"))

    let encoded = try JSONEncoder().encode(linked)
    let decoded = try JSONDecoder().decode(Meeting.self, from: encoded)
    expect(decoded.calendar == link && decoded.titleFollowsCalendar)
    // Older versions only know automatic and manual names; a linked record must still decode there.
    let stored = try require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    expect(stored["titleSource"] as? String == "automatic")
    var legacy = try require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "calendar")
    expect(try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: legacy)).calendar == nil)

    // A meeting started ad hoc and linked afterwards keeps its recordings, transcript, summary and start time.
    var adHoc = Meeting()
    let created = adHoc.createdAt
    adHoc.chunks = [AudioChunk(filename: "system_0.wav", source: .system, start: 0, duration: 60)]
    adHoc.liveSegments = linked.liveSegments
    adHoc.applySummary(MeetingSummary(title: "Release timing", overview: [], decisions: [], actions: [], questions: []))
    expect(adHoc.title == "Release timing")
    adHoc.link(link)
    expect(adHoc.title == "产品周会" && adHoc.titleFollowsCalendar)
    expect(adHoc.createdAt == created && adHoc.chunks.count == 1 && adHoc.liveSegments.count == 1 && adHoc.summary?.title == "Release timing")
    var other = event("planning", start: 60, end: 90, title: "季度规划")
    other.organizer = nil
    adHoc.link(CalendarLink(event: other, account: account))
    expect(adHoc.title == "季度规划" && adHoc.calendar?.eventID == "planning") // Correcting the link follows the new event.
    adHoc.link(nil)
    expect(adHoc.calendar == nil && adHoc.title == "Release timing" && adHoc.titleSource == .automatic && !adHoc.titleFollowsCalendar)

    // Manual names always stay.
    var renamed = Meeting()
    renamed.title = "我的命名"; renamed.titleSource = .manual
    renamed.link(link)
    expect(renamed.title == "我的命名" && renamed.titleSource == .manual && renamed.calendar == link)
    renamed.link(nil)
    expect(renamed.title == "我的命名")
    let named = Meeting(title: "指定名称", calendar: link)
    expect(named.titleSource == .manual && !named.titleFollowsCalendar && named.calendar == link)

    // Untitled events keep the generated name; legacy records named by hand are treated as manual.
    var untitled = Meeting()
    let defaultTitle = untitled.title
    untitled.link(CalendarLink(event: event("untitled", start: 0, end: 30, title: " "), account: account))
    expect(untitled.title == defaultTitle && untitled.titleSource == .automatic && !untitled.titleFollowsCalendar && untitled.calendar != nil)
    var legacyManual = Meeting()
    legacyManual.title = "旧版改名"; legacyManual.titleSource = nil
    legacyManual.link(link)
    expect(legacyManual.title == "旧版改名")
}

private final class Requests: @unchecked Sendable {
    var all: [URLRequest] = []
}

private func formFields(_ request: URLRequest) -> [String: String] {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
    }
    var fields: [String: String] = [:]
    for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    return fields
}

private func idToken(email: String) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["email": email, "hd": "example.com"])
    let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJSUzI1NiJ9.\(encoded).signature"
}

func checkGoogleOAuth() async throws {
    // RFC 7636 appendix B.
    expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let random = PKCE()
    expect(random.verifier.count == 43 && random.verifier != PKCE().verifier && !random.verifier.contains("="))

    expect(GoogleOAuthConfiguration(info: nil) == nil)
    expect(GoogleOAuthConfiguration(info: ["GoogleOAuthClientID": "abc", "GoogleOAuthClientSecret": "s"]) == nil)
    expect(GoogleOAuthConfiguration(info: ["GoogleOAuthClientID": "1-x.apps.googleusercontent.com", "GoogleOAuthClientSecret": " "]) == nil)
    let configuration = try require(GoogleOAuthConfiguration(info: ["GoogleOAuthClientID": " 1-x.apps.googleusercontent.com\n",
                                                                     "GoogleOAuthClientSecret": "unit-secret"]))
    expect(configuration.clientID == "1-x.apps.googleusercontent.com")

    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    let auth = GoogleAuthClient(configuration: configuration, session: session)
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    let redirect = URL(string: "http://127.0.0.1:53682/")!
    let authorization = auth.authorizationURL(redirectURI: redirect, state: "state-1", pkce: pkce,
                                              scopes: GoogleScope.identity + [GoogleScope.calendar], loginHint: "me@example.com")
    let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    expect(authorization.host == "accounts.google.com" && authorization.scheme == "https")
    expect(query["client_id"] == configuration.clientID && query["redirect_uri"] == "http://127.0.0.1:53682/")
    expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" && query["code_challenge_method"] == "S256")
    expect(query["access_type"] == "offline" && query["state"] == "state-1" && query["response_type"] == "code")
    expect(query["scope"] == "openid email https://www.googleapis.com/auth/calendar.events.readonly")
    expect(query["client_secret"] == nil && query["login_hint"] == "me@example.com")

    let requests = Requests()
    var refreshCount = 0
    MockProtocol.handler = { request in
        requests.all.append(request)
        let fields = formFields(request)
        if request.url?.path == "/revoke" { return (200, Data()) }
        switch fields["grant_type"] {
        case "authorization_code":
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": "access-1", "expires_in": 3599,
                "refresh_token": "refresh-1", "scope": "openid email \(GoogleScope.calendar)", "id_token": idToken(email: "Me@Example.com")]))
        case "refresh_token":
            refreshCount += 1
            if fields["refresh_token"] == "revoked" { return (400, Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)) }
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": "access-\(refreshCount + 1)", "expires_in": 3599]))
        default: return (500, Data(#"{"error":"server_error"}"#.utf8))
        }
    }
    let storage = FakeCredentialStorage()
    let googleSession = GoogleSession(auth: auth, storage: storage)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let account = try await googleSession.connect(code: "code-1", redirectURI: redirect, pkce: pkce, now: now)
    expect(account.email == "me@example.com" && account.refreshToken == "refresh-1" && account.scopes.contains(GoogleScope.calendar))
    let exchange = try require(requests.all.first)
    let exchangeFields = formFields(exchange)
    expect(exchange.url?.absoluteString == "https://oauth2.googleapis.com/token" && exchange.httpMethod == "POST")
    expect(exchangeFields["code"] == "code-1" && exchangeFields["code_verifier"] == pkce.verifier)
    expect(exchangeFields["client_id"] == configuration.clientID && exchangeFields["client_secret"] == "unit-secret")
    expect(exchangeFields["redirect_uri"] == "http://127.0.0.1:53682/")
    let stored = try require(storage.value)
    expect(stored.contains("refresh-1") && !stored.contains("access-1") && !stored.contains("unit-secret"))

    let cached = try await googleSession.accessToken(now: now.addingTimeInterval(60))
    expect(cached == "access-1")
    expect(requests.all.count == 1) // A fresh access token is reused.
    let refreshed = try await googleSession.accessToken(now: now.addingTimeInterval(3599 - 30))
    expect(refreshed == "access-2") // Refreshes before expiry.
    expect(formFields(requests.all[1])["refresh_token"] == "refresh-1")
    await googleSession.invalidateAccessToken()
    let replaced = try await googleSession.accessToken(now: now.addingTimeInterval(3600))
    expect(replaced == "access-3")

    // A relaunch reads the account back from the Keychain item.
    let relaunched = GoogleSession(auth: auth, storage: storage)
    let reloaded = try await relaunched.load()
    expect(reloaded?.email == "me@example.com")

    let revoked = FakeCredentialStorage()
    revoked.value = String(decoding: try JSONEncoder().encode(GoogleAccount(email: "me@example.com", refreshToken: "revoked", scopes: [])), as: UTF8.self)
    do { _ = try await GoogleSession(auth: auth, storage: revoked).accessToken(now: now); recordFailure("Expected reconnect") }
    catch { expect(error as? GoogleError == .reconnectRequired) }
    do { _ = try await GoogleSession(auth: auth, storage: FakeCredentialStorage()).accessToken(now: now); recordFailure("Expected not connected") }
    catch { expect(error as? GoogleError == .notConnected) }

    // An authorization that cannot be saved is never used.
    let failing = FakeCredentialStorage(); failing.fail = true
    let unsaved = GoogleSession(auth: auth, storage: failing)
    do { _ = try await unsaved.connect(code: "code-2", redirectURI: redirect, pkce: pkce, now: now); recordFailure("Expected save failure") }
    catch { expect(error is CredentialError) }
    failing.fail = false
    do { _ = try await unsaved.accessToken(now: now); recordFailure("Unsaved authorization was used") }
    catch { expect(error as? GoogleError == .notConnected) }

    MockProtocol.handler = { request in
        requests.all.append(request)
        if formFields(request)["grant_type"] == "authorization_code" {
            return (200, try JSONSerialization.data(withJSONObject: ["access_token": "a", "expires_in": 3599, "id_token": idToken(email: "me@example.com")]))
        }
        return (200, Data())
    }
    do { _ = try await auth.exchange(code: "c", redirectURI: redirect, pkce: pkce); recordFailure("Expected missing refresh token") }
    catch { expect(error as? GoogleError == .missingRefreshToken) }

    requests.all = []
    try await googleSession.disconnect()
    expect(storage.value == nil && storage.deletes == 1)
    let revoke = try require(requests.all.first)
    expect(revoke.url?.absoluteString == "https://oauth2.googleapis.com/revoke" && formFields(revoke)["token"] == "refresh-1")
    do { _ = try await googleSession.accessToken(now: now); recordFailure("Disconnected session still issued tokens") }
    catch { expect(error as? GoogleError == .notConnected) }

    MockProtocol.handler = { _ in (500, Data(#"{"error":"unit-secret leaked"}"#.utf8)) }
    do { _ = try await auth.refresh(GoogleAccount(email: "me@example.com", refreshToken: "r", scopes: [])); recordFailure("Expected server error") }
    catch { expect(!error.localizedDescription.contains("unit-secret")) }
    expect(GoogleAuthClient.email(fromIDToken: "not-a-token") == nil)
}

func checkGoogleCalendarRequests() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
    let client = GoogleCalendarClient(session: URLSession(configuration: config))
    let requests = Requests()
    MockProtocol.handler = { request in
        requests.all.append(request)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = items.first { $0.name == "pageToken" }?.value
        let item: [String: Any] = ["id": page == nil ? "first" : "second", "summary": "Sync",
            "start": ["dateTime": "2026-10-05T10:00:00Z"], "end": ["dateTime": "2026-10-05T11:00:00Z"]]
        var body: [String: Any] = ["items": [item, ["id": "no-times"]]]
        if page == nil { body["nextPageToken"] = "page-2" }
        return (200, try JSONSerialization.data(withJSONObject: body))
    }
    let from = GoogleTimeFixture.date("2026-10-05T08:00:00Z"), to = GoogleTimeFixture.date("2026-10-06T08:00:00Z")
    let events = try await client.events(accessToken: "access-token", from: from, to: to)
    expect(events.map(\.id) == ["first", "second"])
    let first = try require(requests.all.first)
    let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: first.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    expect(first.url?.host == "www.googleapis.com" && first.url?.path == "/calendar/v3/calendars/primary/events")
    expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    expect(query["timeMin"] == "2026-10-05T08:00:00Z" && query["timeMax"] == "2026-10-06T08:00:00Z")
    expect(query["singleEvents"] == "true" && query["orderBy"] == "startTime" && query["fields"]?.contains("recurringEventId") == true)
    expect(requests.all.count == 2)

    MockProtocol.handler = { _ in (401, Data(#"{"error":{"code":401,"status":"UNAUTHENTICATED"}}"#.utf8)) }
    do { _ = try await client.events(accessToken: "expired", from: from, to: to); recordFailure("Expected unauthorized") }
    catch { expect(error as? GoogleCalendarClient.Failure == .unauthorized) }
    MockProtocol.handler = { _ in (403, Data(#"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#.utf8)) }
    do { _ = try await client.events(accessToken: "token", from: from, to: to); recordFailure("Expected disabled API") }
    catch { expect(error.localizedDescription.contains("Calendar API")) }
}

func checkLoopbackRedirect() async throws {
    func deliver(_ receiver: LoopbackRedirectReceiver, _ query: String) async throws -> (Int, String) {
        let url = try require(URL(string: receiver.redirectURI.absoluteString + query))
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }
    let receiver = try await LoopbackRedirectReceiver.start(state: "expected")
    expect(receiver.redirectURI.host == "127.0.0.1" && receiver.redirectURI.port != nil && receiver.redirectURI.path == "/")
    let waiting = Task { try await receiver.code(timeout: 10) }
    let (missing, _) = try await deliver(receiver, "favicon.ico")
    expect(missing == 404) // Unrelated browser requests do not end the flow.
    let (status, page) = try await deliver(receiver, "?state=expected&code=4%2Fabc&scope=email")
    expect(status == 200 && page.contains("已完成 Google 授权"))
    let code = try await waiting.value
    expect(code == "4/abc")

    let forged = try await LoopbackRedirectReceiver.start(state: "expected")
    let forgedWait = Task { try await forged.code(timeout: 10) }
    _ = try await deliver(forged, "?state=other&code=x")
    do { _ = try await forgedWait.value; recordFailure("Accepted a forged state") }
    catch { expect(error as? GoogleError == .stateMismatch) }

    let denied = try await LoopbackRedirectReceiver.start(state: "s")
    let deniedWait = Task { try await denied.code(timeout: 10) }
    _ = try await deliver(denied, "?error=access_denied&state=s")
    do { _ = try await deniedWait.value; recordFailure("Expected denial") }
    catch { expect(error as? GoogleError == .denied("access_denied")) }

    let idle = try await LoopbackRedirectReceiver.start(state: "s")
    do { _ = try await idle.code(timeout: 0.2); recordFailure("Expected timeout") }
    catch { expect(error as? GoogleError == .timedOut) }
    let cancelled = try await LoopbackRedirectReceiver.start(state: "s")
    let cancelledWait = Task { try await cancelled.code(timeout: 10) }
    cancelled.cancel()
    do { _ = try await cancelledWait.value; recordFailure("Expected cancellation") }
    catch { expect(error is CancellationError) }
}
