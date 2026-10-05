import Foundation
import MeetingCore

final class MemoryCredentialStorage: CredentialStorage {
    var value: String?
    func read() throws -> String? { value }
    func save(_ key: String) throws { value = key }
    func delete() throws { value = nil }
}

/// A configured calendar that never reaches the network or the Keychain.
@MainActor func offlineCalendar() -> CalendarController {
    CalendarController(info: [GoogleOAuthConfiguration.clientIDKey: "1-offline.apps.googleusercontent.com",
                              GoogleOAuthConfiguration.clientSecretKey: "offline"], storage: MemoryCredentialStorage())
}

func sampleEvent(_ id: String, _ title: String, start: Double, end: Double, now: Date, join: Bool = true, series: String? = nil) -> CalendarEvent {
    CalendarEvent(id: id, recurringEventID: series, title: title, start: now.addingTimeInterval(start * 60), end: now.addingTimeInterval(end * 60),
                  organizer: CalendarPerson(email: "lin@example.com", name: "林晓", isOrganizer: true),
                  attendees: [CalendarPerson(email: "me@example.com", response: "accepted", isSelf: true),
                              CalendarPerson(email: "lin@example.com", name: "林晓", response: "accepted", isOrganizer: true),
                              CalendarPerson(email: "anna@example.com", name: "Anna", response: "tentative"),
                              CalendarPerson(email: "zhou@example.com", name: "周明", response: "needsAction")],
                  joinURL: join ? URL(string: "https://meet.google.com/abc-defg-hij") : nil)
}

func sampleBrief(_ eventID: String, account: String = "me@example.com", earlier: UUID? = nil) -> MeetingBrief {
    var sources = [BriefSource(id: "calendar:\(eventID)", kind: .calendar, title: "产品周会：测试版发布计划", detail: "组织者 林晓 · 4 人受邀"),
                   BriefSource(id: "email:t1", kind: .email, title: "Re: 测试版发布时间", detail: "林晓 · 3 封", date: Date().addingTimeInterval(-86400),
                               excerpt: "如果周三前回归测试能完成，我们建议把测试版发布放在下周五。", link: URL(string: "https://mail.google.com/mail/u/0/#all/t1")),
                   BriefSource(id: "email:t2", kind: .email, title: "企业版定价草案 v2", detail: "Anna · 2 封", date: Date().addingTimeInterval(-3 * 86400))]
    if let earlier { sources.append(BriefSource(id: "meeting:\(earlier.uuidString)", kind: .meeting, title: "产品周会（上周）", detail: "9月28日", meetingID: earlier)) }
    let previous = earlier.map { [BriefPoint(text: "上周决定保留三档定价，非营利折扣待定。", sources: ["meeting:\($0.uuidString)"])] } ?? []
    return MeetingBrief(account: account, eventID: eventID, eventEnd: Date().addingTimeInterval(3600), fingerprint: "preview",
        generatedAt: Date().addingTimeInterval(-1800), language: "zh", mailIncluded: true,
        purpose: [BriefPoint(text: "确认测试版发布日期，并对齐企业版定价。", sources: ["calendar:\(eventID)", "email:t1"])],
        correspondence: [BriefPoint(text: "林晓提议：周三前完成回归测试则下周五发布测试版。", sources: ["email:t1"]),
                         BriefPoint(text: "Anna 发来定价草案 v2，企业版上调 10%，等待确认。", sources: ["email:t2"])],
        previous: previous,
        openItems: [BriefPoint(text: "回归测试能否在周三前完成？", sources: ["email:t1"]),
                    BriefPoint(text: "企业版是否采用草案 v2 的价格？", sources: ["email:t2"])],
        sources: sources)
}

// Exercise the real controller's start entries and linking against local data, without capture or API work.
@MainActor func checkCalendarFlow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarFlowChecks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(root: root)
    let calendar = offlineCalendar()
    let controller = MeetingController(storageRoot: root, calendar: calendar)
    controller.error = nil
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw MeetingError.message(message) }
    }
    let now = Date()
    let due = sampleEvent("due", "产品周会", start: 5, end: 35, now: now)
    let overlap = sampleEvent("overlap", "客户电话", start: 0, end: 30, now: now)
    let later = sampleEvent("later", "季度规划", start: 60, end: 90, now: now)

    try check(calendar.configured, "Offline calendar is not configured")
    calendar.preview(account: nil, events: [due, overlap], now: now)
    try check(controller.prominentEvents.isEmpty && controller.startableEvents.isEmpty, "Disconnected calendar led the start entries")

    calendar.preview(account: "me@example.com", events: [due, overlap, later], now: now)
    try check(controller.prominentEvents.map(\.id) == ["overlap", "due"], "Overlapping meetings were not both offered")
    try check(controller.upcomingEvents.map(\.id) == ["overlap", "due", "later"], "Agenda left out a later meeting")

    // Calendar items and records share one selection; choosing a record replaces the calendar item.
    controller.calendarSelection = .event("later")
    try check(controller.selectedEvent?.id == "later", "Selected event did not resolve")
    controller.selectedID = UUID()
    try check(controller.calendarSelection == nil && controller.selectedEvent == nil, "Selecting a record kept the calendar item")
    controller.calendarSelection = .agenda
    controller.selectedID = nil
    try check(controller.calendarSelection == .agenda, "Clearing the record selection dropped the agenda")
    controller.calendarSelection = nil
    await controller.requestStart()
    try check(controller.startChooserPresented, "Generic start did not ask which meeting")
    try check(controller.meetings.isEmpty && (try store.all()).isEmpty, "Generic start created a record before a choice")
    controller.startChooserPresented = false
    controller.recording = true
    await controller.requestStart()
    try check(!controller.startChooserPresented, "A running meeting was interrupted by the chooser")
    controller.recording = false

    // A meeting must not silently become ad hoc when the account went away after it was shown.
    calendar.preview(account: nil, events: [due], now: now)
    await controller.startMeeting(event: due)
    try check(controller.error?.contains("Google 账号已断开") == true && controller.meetings.isEmpty, "Unlinked start was not refused")
    controller.error = nil
    calendar.preview(account: "me@example.com", events: [due, overlap, later], now: now)

    // Linking afterwards keeps recordings, transcript, summary and the actual start time.
    var adHoc = Meeting()
    adHoc.state = "complete"; adHoc.duration = 600
    adHoc.chunks = [AudioChunk(filename: "system_0.wav", source: .system, start: 0, duration: 300)]
    adHoc.liveSegments = [TranscriptSegment(id: "s1", source: .system, start: 0, end: 3, text: "Ship Friday", translation: "周五发布")]
    adHoc.applySummary(MeetingSummary(title: "发布时间", overview: [.init(text: "周五发布", evidence: ["s1"])],
                                      decisions: [], actions: [], questions: []))
    try store.save(adHoc)
    controller.meetings = [adHoc]; controller.selectedID = adHoc.id
    controller.linkMeeting(adHoc.id, to: due)
    var reloaded = try store.load(adHoc.id)
    try check(reloaded.calendar?.eventID == "due" && reloaded.calendar?.account == "me@example.com", "Link was not saved")
    try check(reloaded.title == "产品周会" && reloaded.titleFollowsCalendar, "Linked record did not take the event name")
    try check(reloaded.createdAt == adHoc.createdAt && reloaded.chunks == adHoc.chunks && reloaded.liveSegments == adHoc.liveSegments
              && reloaded.summary?.overview.first?.text == "周五发布" && reloaded.state == "complete", "Linking changed recorded data")
    try check(controller.prominentEvents.map(\.id) == ["overlap"], "A recorded occurrence still led the start entries")
    try check(controller.records(for: due).map(\.id) == [adHoc.id] && controller.startableEvents.count == 2, "Recorded occurrence is not offered for appending")

    try check(try store.load(adHoc.id).brief == nil, "A brief appeared without one being prepared")
    // A prepared brief goes with the record when it is linked, and leaves when the link does.
    controller.briefs.preview([sampleBrief("overlap")])
    controller.linkMeeting(adHoc.id, to: overlap)
    try check(try store.load(adHoc.id).brief?.eventID == "overlap", "Linking did not keep the prepared brief")
    try check(try store.load(adHoc.id).title == "客户电话" && controller.prominentEvents.map(\.id) == ["due"], "Correcting the link failed")
    controller.renameMeeting("我的名字")
    controller.linkMeeting(adHoc.id, to: due)
    try check(try store.load(adHoc.id).title == "我的名字", "Relinking replaced a manual name")

    controller.processing = true
    controller.linkMeeting(adHoc.id, to: nil)
    controller.processing = false
    try check(try store.load(adHoc.id).calendar != nil, "Busy controller changed a link")

    // A link that cannot be saved is not shown as saved.
    let folder = store.folder(adHoc.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    controller.linkMeeting(adHoc.id, to: nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    try check(controller.error?.hasPrefix("关联未保存") == true && controller.meetings[0].calendar?.eventID == "due", "Failed save changed the record")
    controller.error = nil

    controller.linkMeeting(adHoc.id, to: nil)
    reloaded = try store.load(adHoc.id)
    try check(reloaded.calendar == nil && reloaded.title == "我的名字" && reloaded.liveSegments == adHoc.liveSegments, "Unlinking failed")
    try check(reloaded.brief == nil && reloaded.summary?.overview.first?.text == "周五发布", "Unlinking kept another event's brief or lost the summary")

    // Late arrivals still see the meeting until its scheduled end; after that it stops leading.
    calendar.preview(account: "me@example.com", events: [due, overlap, later], now: now.addingTimeInterval(32 * 60))
    try check(controller.prominentEvents.map(\.id) == ["due"], "Late arrival lost the current meeting")
    calendar.preview(account: "me@example.com", events: [due, overlap, later], now: now.addingTimeInterval(120 * 60))
    try check(controller.prominentEvents.isEmpty, "Ended meetings still led the start entries")
    print("Calendar start flow: \(checks) assertions, 0 failures")
}
