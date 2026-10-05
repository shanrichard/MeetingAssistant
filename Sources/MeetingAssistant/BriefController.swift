import Foundation
import MeetingCore

/// Prepares pre-meeting briefs automatically for upcoming meetings, one at a time, and keeps them on this Mac.
@MainActor final class BriefController: ObservableObject {
    enum State: Equatable { case generating, failed(String) }
    @Published private(set) var briefs: [String: MeetingBrief] = [:]
    @Published private(set) var states: [String: State] = [:]
    private var failures: [String: Date] = [:]
    private let store: BriefStore?
    private let calendar: CalendarController
    private let gmail: GmailClient
    private var running = false
    // Provided by the meeting controller, which owns the OpenAI key and the records.
    var makeClient: () throws -> OpenAIClient = { throw CredentialError.missing }
    var history: (CalendarEvent) -> [Meeting] = { _ in [] }
    var language: () -> String = { "zh" }
    var hasOpenAIKey: () -> Bool = { false }

    private let diagnostics: URL?

    init(calendar: CalendarController, storeRoot: URL? = nil, apiSession: URLSession? = nil) {
        self.calendar = calendar
        store = try? BriefStore(root: storeRoot)
        // Beside the cache; counts, times and errors only, never titles, people or mail.
        diagnostics = store?.root.deletingLastPathComponent().appendingPathComponent("brief-diagnostics.json")
        gmail = GmailClient(session: apiSession)
        reload()
    }

    func reload() {
        guard let store, let account = calendar.account else { briefs = [:]; return }
        store.prune(endedBefore: Date().addingTimeInterval(-7 * 86400))
        briefs = Dictionary(store.all(account: account).map { ($0.eventID, $0) }) { first, _ in first }
    }

    func brief(for eventID: String) -> MeetingBrief? { briefs[eventID] }

    /// Generates every brief that is due, soonest meeting first. Runs after each calendar sync.
    func generateDue() async {
        guard !running, calendar.account != nil, hasOpenAIKey() else { return }
        running = true; defer { running = false }
        for event in CalendarSchedule.upcoming(calendar.events, at: Date()) {
            guard calendar.account != nil else { return }
            if BriefSchedule.isDue(event, brief: briefs[event.id], mailAvailable: calendar.mailAuthorized,
                                   lastFailure: failures[event.id], now: Date()) {
                await generate(event)
            }
        }
    }

    /// Generates now, regardless of schedule; used by "刷新" and the first view of a far-off meeting.
    func generate(_ event: CalendarEvent) async {
        guard let account = calendar.account, states[event.id] != .generating else { return }
        states[event.id] = .generating
        do {
            let brief = try await make(event, account: account, before: nil)
            guard calendar.account == account else { states[event.id] = nil; return }
            try? store?.save(brief)
            briefs[event.id] = brief; states[event.id] = nil; failures[event.id] = nil
            saveDiagnostics(lastError: nil, mailThreads: brief.count(.email), points: brief.points.count)
        } catch {
            states[event.id] = .failed(error.localizedDescription); failures[event.id] = Date()
            saveDiagnostics(lastError: error.localizedDescription, mailThreads: nil, points: nil)
        }
    }

    private func saveDiagnostics(lastError: String?, mailThreads: Int?, points: Int?) {
        guard let diagnostics else { return }
        struct Snapshot: Encodable {
            let at: Date, briefs: Int, failures: Int, mailAuthorized: Bool
            let lastError: String?, lastCitedMailThreads: Int?, lastPoints: Int?
        }
        let snapshot = Snapshot(at: Date(), briefs: briefs.count, failures: failures.count, mailAuthorized: calendar.mailAuthorized,
                                lastError: lastError, lastCitedMailThreads: mailThreads, lastPoints: points)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(snapshot).write(to: diagnostics, options: .atomic)
    }

    /// A brief for a record made without one, from what the record kept about its event. Not cached.
    func briefAfterwards(for link: CalendarLink) async throws -> MeetingBrief {
        guard let account = calendar.account, account == link.account else { throw GoogleError.notConnected }
        let event = CalendarEvent(id: link.eventID, calendarID: link.calendarID, iCalUID: link.iCalUID, recurringEventID: link.recurringEventID,
                                  originalStart: link.originalStart, title: link.title, start: link.scheduledStart, end: link.scheduledEnd,
                                  organizer: link.organizer, attendees: link.attendees, joinURL: link.joinURL)
        return try await make(event, account: account, before: link.scheduledEnd)
    }

    private func make(_ event: CalendarEvent, account: String, before: Date?) async throws -> MeetingBrief {
        let client = try makeClient()
        var threads: [MailThread] = []
        let mailIncluded = calendar.mailAuthorized
        if mailIncluded {
            let queries = GmailQuery.queries(for: event, account: account, before: before)
            do {
                threads = try await calendar.withAccessToken { [gmail] token in try await gmail.threads(accessToken: token, queries: queries) }
            } catch GoogleError.mailNotAuthorized {
                calendar.mailAccessRevoked()
                return try await make(event, account: account, before: before)
            }
        }
        let context = BriefContext.make(event: event, account: account, threads: threads, history: history(event))
        return try await client.brief(context, event: event, account: account, language: language(), mailIncluded: mailIncluded)
    }

    /// Mail-derived text does not outlive the connection that allowed reading it.
    func clear() {
        try? store?.deleteAll()
        briefs = [:]; states = [:]; failures = [:]
    }

    /// Fixed briefs for offline previews and checks.
    func preview(_ briefs: [MeetingBrief], states: [String: State] = [:]) {
        self.briefs = Dictionary(briefs.map { ($0.eventID, $0) }) { first, _ in first }
        self.states = states
    }
}
