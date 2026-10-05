import Foundation
import CryptoKit

enum SHA256Digest {
    static func hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct CalendarPerson: Codable, Equatable, Sendable {
    public var email: String
    public var name: String?
    /// Google response status: accepted, declined, tentative or needsAction.
    public var response: String?
    public var isSelf: Bool
    public var isOrganizer: Bool
    public init(email: String, name: String? = nil, response: String? = nil, isSelf: Bool = false, isOrganizer: Bool = false) {
        self.email = email; self.name = name; self.response = response; self.isSelf = isSelf; self.isOrganizer = isOrganizer
    }
    public var displayName: String {
        let name = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? email : name
    }
}

/// One occurrence of a calendar event; recurring events are expanded into instances.
public struct CalendarEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var calendarID: String
    public var iCalUID: String?
    public var recurringEventID: String?
    public var originalStart: Date?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var status: String
    public var eventType: String
    public var organizer: CalendarPerson?
    public var attendees: [CalendarPerson]
    public var joinURL: URL?
    /// The invitation's description as plain text, for the pre-meeting brief. Not kept on meeting records.
    public var notes: String?
    public init(id: String, calendarID: String = "primary", iCalUID: String? = nil, recurringEventID: String? = nil,
                originalStart: Date? = nil, title: String, start: Date, end: Date, isAllDay: Bool = false,
                status: String = "confirmed", eventType: String = "default", organizer: CalendarPerson? = nil,
                attendees: [CalendarPerson] = [], joinURL: URL? = nil, notes: String? = nil) {
        self.id = id; self.calendarID = calendarID; self.iCalUID = iCalUID; self.recurringEventID = recurringEventID
        self.originalStart = originalStart; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.status = status; self.eventType = eventType; self.organizer = organizer; self.attendees = attendees; self.joinURL = joinURL
        self.notes = notes
    }
    /// Changes when what a brief is built from changes; response updates alone do not count.
    public var fingerprint: String {
        let people = attendees.map { $0.email.lowercased() }.sorted().joined(separator: ",")
        let text = [title, String(start.timeIntervalSince1970), String(end.timeIntervalSince1970), people, notes ?? ""].joined(separator: "\u{1F}")
        return SHA256Digest.hex(text)
    }
    public var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "（无标题日程）" : title
    }
    public var selfResponse: String? { attendees.first(where: \.isSelf)?.response }

    /// Parses one item of a Google Calendar events.list response. Returns nil for items without usable times.
    public static func google(_ item: [String: Any], calendarID: String = "primary", timeZone: TimeZone = .current) -> CalendarEvent? {
        guard let id = item["id"] as? String,
              let start = GoogleTime.parse(item["start"], timeZone: timeZone),
              let end = GoogleTime.parse(item["end"], timeZone: timeZone) else { return nil }
        func person(_ value: Any?) -> CalendarPerson? {
            guard let value = value as? [String: Any], let email = value["email"] as? String else { return nil }
            return CalendarPerson(email: email, name: value["displayName"] as? String, response: value["responseStatus"] as? String,
                                  isSelf: value["self"] as? Bool ?? false, isOrganizer: value["organizer"] as? Bool ?? false)
        }
        // Rooms and equipment are booked as attendees but are not people.
        let attendees = (item["attendees"] as? [[String: Any]] ?? [])
            .filter { $0["resource"] as? Bool != true }.compactMap(person)
        var organizer = person(item["organizer"])
        organizer?.isOrganizer = true
        return CalendarEvent(id: id, calendarID: calendarID, iCalUID: item["iCalUID"] as? String,
            recurringEventID: item["recurringEventId"] as? String,
            originalStart: GoogleTime.parse(item["originalStartTime"], timeZone: timeZone)?.date,
            title: item["summary"] as? String ?? "", start: start.date, end: end.date, isAllDay: start.isAllDay,
            status: item["status"] as? String ?? "confirmed", eventType: item["eventType"] as? String ?? "default",
            organizer: organizer, attendees: attendees, joinURL: joinURL(item),
            notes: (item["description"] as? String).map(plainNotes).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Google descriptions are often HTML; keep readable text, bounded.
    static func plainNotes(_ description: String) -> String {
        let text = MailText.stripHTML(description).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 3000 ? String(text.prefix(3000)) + "…" : text
    }

    static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]
    private static func joinURL(_ item: [String: Any]) -> URL? {
        if let link = item["hangoutLink"] as? String, let url = URL(string: link), url.scheme == "https" { return url }
        let entryPoints = (item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        if let video = entryPoints.first(where: { $0["entryPointType"] as? String == "video" })?["uri"] as? String,
           let url = URL(string: video), url.scheme == "https" { return url }
        // Zoom and Teams invitations often only carry the link in the location or description.
        let text = [item["location"], item["description"]].compactMap { $0 as? String }.joined(separator: "\n")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { url in
            guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

enum GoogleTime {
    struct Value { var date: Date; var isAllDay: Bool }
    static func parse(_ value: Any?, timeZone: TimeZone) -> Value? {
        guard let value = value as? [String: Any] else { return nil }
        if let text = value["dateTime"] as? String, let date = timestamp(text) { return Value(date: date, isAllDay: false) }
        if let text = value["date"] as? String {
            // All-day dates are calendar days, not instants; read them in the local time zone.
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: text) { return Value(date: date, isAllDay: true) }
        }
        return nil
    }
    static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Identifies one occurrence: recurring instances have their own event ID, stable across rescheduling.
public struct CalendarEventKey: Codable, Hashable, Sendable {
    public var account: String
    public var calendarID: String
    public var eventID: String
    public init(account: String, calendarID: String, eventID: String) {
        self.account = account.lowercased(); self.calendarID = calendarID; self.eventID = eventID
    }
}

/// What a meeting record keeps about its calendar event, captured when it is linked.
public struct CalendarLink: Codable, Equatable, Sendable {
    public var account: String
    public var calendarID: String
    public var eventID: String
    public var recurringEventID: String?
    public var originalStart: Date?
    public var iCalUID: String?
    public var title: String
    public var scheduledStart: Date
    public var scheduledEnd: Date
    public var organizer: CalendarPerson?
    /// Invitees and their responses: context only, not evidence of who attended or spoke.
    public var attendees: [CalendarPerson]
    public var joinURL: URL?
    public var linkedAt: Date
    public init(event: CalendarEvent, account: String, linkedAt: Date = Date()) {
        self.account = account.lowercased(); calendarID = event.calendarID; eventID = event.id
        recurringEventID = event.recurringEventID; originalStart = event.originalStart; iCalUID = event.iCalUID
        title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduledStart = event.start; scheduledEnd = event.end
        organizer = event.organizer; attendees = event.attendees; joinURL = event.joinURL
        self.linkedAt = linkedAt
    }
    public var key: CalendarEventKey { CalendarEventKey(account: account, calendarID: calendarID, eventID: eventID) }
    public var displayTitle: String { title.isEmpty ? "（无标题日程）" : title }
}

public enum CalendarSchedule {
    /// How early an upcoming event becomes the main way to start. A design value pending real use.
    public static let lead: TimeInterval = 10 * 60

    /// Timed events the user has not declined; all-day items, cancellations, focus time and out-of-office are excluded.
    public static func isMeeting(_ event: CalendarEvent) -> Bool {
        !event.isAllDay && event.status != "cancelled" && event.eventType == "default"
            && event.selfResponse != "declined" && event.end > event.start
    }
    /// Events to offer when starting at `now`: from `lead` before the start until the scheduled end.
    public static func startable(_ events: [CalendarEvent], at now: Date) -> [CalendarEvent] {
        events.filter { isMeeting($0) && $0.start.addingTimeInterval(-lead) <= now && now < $0.end }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }
    /// Startable events that have no record yet. An already recorded occurrence stops leading the window.
    public static func prominent(_ events: [CalendarEvent], at now: Date, account: String,
                                 recorded: Set<CalendarEventKey>) -> [CalendarEvent] {
        startable(events, at: now).filter { !recorded.contains(CalendarEventKey(account: account, calendarID: $0.calendarID, eventID: $0.id)) }
    }
    /// Meetings that have not ended yet, soonest first, for the agenda.
    public static func upcoming(_ events: [CalendarEvent], at now: Date) -> [CalendarEvent] {
        events.filter { isMeeting($0) && now < $0.end }.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }
    /// Earlier records from the same recurring series, newest first.
    public static func seriesRecords(_ meetings: [Meeting], for event: CalendarEvent, account: String) -> [Meeting] {
        guard let series = event.recurringEventID else { return [] }
        return meetings.filter { meeting in
            guard let link = meeting.calendar else { return false }
            return link.recurringEventID == series && link.eventID != event.id && link.account == account.lowercased()
        }.sorted { $0.createdAt > $1.createdAt }
    }
    /// Candidates for linking an existing record: meetings that overlap the hours around when it started.
    public static func linkable(_ events: [CalendarEvent], around date: Date) -> [CalendarEvent] {
        events.filter(isMeeting).sorted {
            (abs($0.start.timeIntervalSince(date)), $0.id) < (abs($1.start.timeIntervalSince(date)), $1.id)
        }
    }
}
