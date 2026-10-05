import Foundation

/// Reads the connected account's primary calendar. Requests go only to the fixed Google API host.
public final class GoogleCalendarClient: @unchecked Sendable {
    public static let eventsEndpoint = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
    static let fields = "nextPageToken,items(id,iCalUID,recurringEventId,originalStartTime,status,summary,start,end,eventType,"
        + "attendees(email,displayName,responseStatus,self,organizer,resource),organizer(email,displayName,self),"
        + "hangoutLink,conferenceData(entryPoints(entryPointType,uri)),location,description)"
    private let session: URLSession
    public init(session: URLSession? = nil) { self.session = session ?? GoogleAuthClient.makeSession() }

    /// Expanded occurrences that end after `from` and start before `to`.
    public func events(accessToken: String, from: Date, to: Date, timeZone: TimeZone = .current) async throws -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var pageToken: String?
        // A day of meetings fits in one page; the cap only guards against a pathological calendar.
        for _ in 0..<5 {
            var components = URLComponents(url: Self.eventsEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "timeMin", value: GoogleTime.string(from)),
                                     URLQueryItem(name: "timeMax", value: GoogleTime.string(to)),
                                     URLQueryItem(name: "singleEvents", value: "true"),
                                     URLQueryItem(name: "orderBy", value: "startTime"),
                                     URLQueryItem(name: "maxResults", value: "100"),
                                     URLQueryItem(name: "fields", value: Self.fields)]
                + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleError.invalidResponse }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, object: object) }
            events += (object["items"] as? [[String: Any]] ?? []).compactMap { CalendarEvent.google($0, timeZone: timeZone) }
            pageToken = object["nextPageToken"] as? String
            if pageToken == nil { break }
        }
        return events
    }

    public enum Failure: Error, Equatable { case unauthorized }

    static func error(status: Int, object: [String: Any]) -> Error {
        if status == 401 { return Failure.unauthorized }
        let detail = object["error"] as? [String: Any]
        let reason = ((detail?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (detail?["status"] as? String) ?? ""
        switch reason {
        case "insufficientPermissions", "PERMISSION_DENIED", "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
            return GoogleError.server("没有读取日历的权限，请重新连接 Google 账号并允许读取日历。")
        case "accessNotConfigured", "SERVICE_DISABLED":
            return GoogleError.server("组织的 Google 项目尚未启用 Calendar API，请联系管理员。")
        case "rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded":
            return GoogleError.server("日历请求过于频繁，稍后会自动重试。")
        default:
            return GoogleError.server("日历返回 HTTP \(status)")
        }
    }
}
