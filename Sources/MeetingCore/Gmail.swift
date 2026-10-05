import Foundation

public struct MailMessage: Codable, Equatable, Sendable {
    public var from: String
    public var date: Date?
    public var text: String
    public init(from: String, date: Date?, text: String) { self.from = from; self.date = date; self.text = text }
}

public struct MailThread: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var subject: String
    public var messages: [MailMessage]
    public init(id: String, subject: String, messages: [MailMessage]) { self.id = id; self.subject = subject; self.messages = messages }
    public var lastDate: Date? { messages.compactMap(\.date).max() }
}

/// Searches that find mail about one meeting: exchanges with its other invitees, and threads naming it.
public enum GmailQuery {
    /// Calendar invitations and replies describe the event itself, which the calendar source already covers.
    static let exclusions = "-from:calendar-notification@google.com -filename:ics -category:promotions -category:social"
    /// Large meetings make "anyone invited" match most of the mailbox, so only the title is searched.
    public static let maximumParticipants = 15

    /// `before` bounds mail to what existed around the meeting when the brief is prepared afterwards.
    public static func queries(for event: CalendarEvent, account: String, before: Date? = nil) -> [String] {
        let me = account.lowercased()
        var people = event.attendees.filter { !$0.isSelf && $0.email.lowercased() != me }.map { $0.email.lowercased() }
        if let organizer = event.organizer?.email.lowercased(), organizer != me, !people.contains(organizer) { people.append(organizer) }
        var result: [String] = []
        if !people.isEmpty, people.count <= maximumParticipants {
            let terms = people.map { "from:\($0) to:\($0) cc:\($0)" }.joined(separator: " ")
            result.append("newer_than:60d \(exclusions) {\(terms)}")
        }
        if let phrase = titlePhrase(event.title) {
            result.append("newer_than:90d \(exclusions) \"\(phrase)\"")
        }
        guard let before else { return result }
        // Gmail compares whole days, so the day after the meeting still includes same-day mail.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy/MM/dd"
        let bound = formatter.string(from: before.addingTimeInterval(86400))
        return result.map { $0 + " before:\(bound)" }
    }

    /// A title is only searched when it is specific enough to identify the topic.
    static func titlePhrase(_ title: String) -> String? {
        let cleaned = title.replacingOccurrences(of: "\"", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let generic: Set<String> = ["meeting", "sync", "weekly", "weekly sync", "1:1", "1on1", "standup", "stand-up", "会议", "周会", "例会", "站会", "同步"]
        guard !generic.contains(cleaned.lowercased()) else { return nil }
        let isCJK = cleaned.unicodeScalars.contains { $0.properties.isIdeographic }
        return cleaned.count >= (isCJK ? 3 : 6) ? String(cleaned.prefix(80)) : nil
    }
}

/// Plain text from Gmail payloads: the newest content of each message, without quoted history.
public enum MailText {
    public static let messageLimit = 1200

    public static func body(_ payload: [String: Any]) -> String {
        if let plain = part(payload, mimeType: "text/plain") { return clean(plain) }
        if let html = part(payload, mimeType: "text/html") { return clean(stripHTML(html)) }
        return ""
    }

    static func part(_ payload: [String: Any], mimeType: String) -> String? {
        if (payload["mimeType"] as? String)?.lowercased() == mimeType,
           let data = (payload["body"] as? [String: Any])?["data"] as? String, let text = decode(data) { return text }
        for child in payload["parts"] as? [[String: Any]] ?? [] {
            if let text = part(child, mimeType: mimeType) { return text }
        }
        return nil
    }

    static func decode(_ base64URL: String) -> String? {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</?(p|div|li|tr|h[1-6])(\\s[^>]*)?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }

    /// Drops quoted replies and signatures' trailing noise, collapses whitespace and bounds the length.
    public static func clean(_ text: String) -> String {
        var kept: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { continue }
            let quoteStart = line.range(of: "^On .+wrote:$", options: .regularExpression) != nil
                || line.range(of: "^(在|于).+(写道|wrote)[:：]$", options: .regularExpression) != nil
                || line.hasPrefix("-----Original Message-----") || line.hasPrefix("________________________________")
                || (line.hasPrefix("From: ") && !kept.isEmpty) || (line.hasPrefix("发件人：") && !kept.isEmpty)
            if quoteStart { break }
            kept.append(line)
        }
        let joined = kept.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count > messageLimit ? String(joined.prefix(messageLimit)) + "…" : joined
    }

    public static func thread(_ object: [String: Any], keepLast: Int = 3) -> MailThread? {
        guard let id = object["id"] as? String else { return nil }
        let messages = (object["messages"] as? [[String: Any]] ?? []).map { message -> (MailMessage, String) in
            let payload = message["payload"] as? [String: Any] ?? [:]
            let headers = Dictionary((payload["headers"] as? [[String: Any]] ?? []).compactMap { header -> (String, String)? in
                guard let name = header["name"] as? String, let value = header["value"] as? String else { return nil }
                return (name.lowercased(), value)
            }) { first, _ in first }
            let date = (message["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            var text = body(payload)
            if text.isEmpty { text = (message["snippet"] as? String) ?? "" }
            return (MailMessage(from: headers["from"] ?? "", date: date, text: text), headers["subject"] ?? "")
        }
        guard !messages.isEmpty else { return nil }
        let subject = messages.first { !$0.1.isEmpty }?.1 ?? "（无主题）"
        return MailThread(id: id, subject: subject, messages: messages.suffix(keepLast).map(\.0))
    }
}

/// Reads the connected mailbox. Requests go only to the fixed Gmail API host.
public final class GmailClient: @unchecked Sendable {
    public static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    private let session: URLSession
    public init(session: URLSession? = nil) { self.session = session ?? GoogleAuthClient.makeSession() }

    public func threadIDs(accessToken: String, query: String, limit: Int = 10) async throws -> [String] {
        var components = URLComponents(url: Self.base.appendingPathComponent("threads"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(limit))]
        let object = try await get(components.url!, accessToken: accessToken)
        return (object["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    public func thread(accessToken: String, id: String) async throws -> MailThread? {
        var components = URLComponents(url: Self.base.appendingPathComponent("threads").appendingPathComponent(id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        return MailText.thread(try await get(components.url!, accessToken: accessToken))
    }

    /// Threads for one meeting, those found by several searches first, then the most recent.
    public func threads(accessToken: String, queries: [String], limit: Int = 8) async throws -> [MailThread] {
        var hits: [String: Int] = [:], order: [String] = []
        for query in queries {
            for id in try await threadIDs(accessToken: accessToken, query: query) {
                if hits[id] == nil { order.append(id) }
                hits[id, default: 0] += 1
            }
        }
        let chosen = order.enumerated().sorted { (hits[$0.element]!, -$0.offset) > (hits[$1.element]!, -$1.offset) }
            .prefix(limit).map(\.element)
        var threads: [MailThread] = []
        for id in chosen { if let thread = try await thread(accessToken: accessToken, id: id) { threads.append(thread) } }
        return threads
    }

    private func get(_ url: URL, accessToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw GoogleCalendarClient.Failure.unauthorized }
            let detail = object["error"] as? [String: Any]
            let reason = ((detail?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (detail?["status"] as? String) ?? ""
            switch reason {
            case "insufficientPermissions", "PERMISSION_DENIED", "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
                throw GoogleError.mailNotAuthorized
            case "accessNotConfigured", "SERVICE_DISABLED":
                throw GoogleError.server("组织的 Google 项目尚未启用 Gmail API，请联系管理员。")
            default:
                throw GoogleError.server("邮件返回 HTTP \(http.statusCode)")
            }
        }
        return object
    }
}
