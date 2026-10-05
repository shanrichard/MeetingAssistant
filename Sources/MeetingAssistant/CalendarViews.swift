import SwiftUI
import MeetingCore

func eventTimeRange(_ start: Date, _ end: Date) -> String {
    let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
    let from = start.formatted(Calendar.current.isDateInToday(start) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute())
    return from + "–" + (sameDay ? end.formatted(.dateTime.hour().minute()) : end.formatted(.dateTime.month().day().hour().minute()))
}

func eventCountdown(_ event: CalendarEvent, now: Date) -> String {
    let seconds = event.start.timeIntervalSince(now)
    if seconds > 0 {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "即将开始" }
        if minutes < 60 { return "\(minutes) 分钟后开始" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60) 小时后开始" : "\(minutes / 60) 小时 \(minutes % 60) 分后开始" }
        return eventDay(event.start, now: now) + "开始"
    }
    let late = Int(-seconds / 60)
    return late < 1 ? "已到开始时间" : "已到开始时间 · 已过 \(late) 分钟"
}

/// 今天, 明天, a weekday within the week, otherwise the date.
func eventDay(_ date: Date, now: Date, short: Bool = false) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return "今天" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "明天" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    if (0..<7).contains(days) { return date.formatted(.dateTime.weekday(short ? .abbreviated : .wide)) }
    return short ? date.formatted(.dateTime.month(.defaultDigits).day()) : date.formatted(.dateTime.month().day())
}

/// Keeps a named start button from crowding out the rest of its row.
func buttonTitle(_ title: String, limit: Int = 22) -> String {
    title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
}

/// Invitees are context only; this never claims who attended.
func inviteeSummary(_ people: [CalendarPerson], organizer: CalendarPerson?) -> String {
    let others = people.filter { !$0.isSelf }
    guard !others.isEmpty else { return organizer.map { "组织者 \($0.displayName)" } ?? "" }
    let names = others.prefix(2).map(\.displayName).joined(separator: "、")
    return others.count > 2 ? "\(names) 等 \(people.count) 人受邀" : "\(names) 受邀"
}

/// Leads the main window while a calendar meeting is due, whatever the library shows.
struct UpcomingMeetingBanner: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var calendar: CalendarController
    @ObservedObject private var briefs: BriefController
    init(controller: MeetingController) { self.controller = controller; calendar = controller.calendar; briefs = controller.briefs }

    var body: some View {
        // The selected event's own page already offers the same start.
        let events = controller.prominentEvents.filter { $0.id != controller.selectedEvent?.id }
        VStack(spacing: 0) {
            if controller.recording || controller.starting {
                // The current meeting keeps priority; the next one is only mentioned.
                if let next = events.first(where: { controller.liveMeeting?.calendar?.eventID != $0.id }) {
                    nextMeetingNotice(next)
                }
            } else if !events.isEmpty {
                VStack(spacing: 8) { ForEach(events) { card($0) } }
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            if case .failed(let message) = calendar.syncState { syncFailure(message) }
        }
        .background(events.isEmpty || controller.busy ? Color.clear : accent.opacity(0.06))
        .overlay(alignment: .bottom) { if !events.isEmpty || isFailed { Divider() } }
    }

    private var isFailed: Bool { if case .failed = calendar.syncState { return true }; return false }

    private func card(_ event: CalendarEvent) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 20, weight: .medium)).foregroundStyle(accent)
                .frame(width: 34, height: 34).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.displayTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(eventCountdown(event, now: calendar.now)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(event.start <= calendar.now ? Color.orange : accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((event.start <= calendar.now ? Color.orange : accent).opacity(0.13), in: Capsule())
                }
                HStack(spacing: 10) {
                    Text([eventTimeRange(event.start, event.end), inviteeSummary(event.attendees, organizer: event.organizer)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if briefs.brief(for: event.id) != nil {
                        Button { controller.calendarSelection = .event(event.id) } label: { Label("会前说明", systemImage: "doc.text.magnifyingglass") }
                            .buttonStyle(.link).font(.callout)
                    }
                }
            }
            Spacer(minLength: 12)
            if let url = event.joinURL {
                // Opening the meeting link does not start recording.
                Button { NSWorkspace.shared.open(url) } label: { Label("加入会议", systemImage: "video") }
                    .controlSize(.large)
            }
            Button { Task { await controller.startMeeting(event: event) } } label: {
                Label("开始《\(buttonTitle(event.displayTitle, limit: 16))》", systemImage: "record.circle").lineLimit(1)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(controller.busy || controller.audioSetup.working)
            .help("开始记录并关联这场日程")
        }
    }

    private func nextMeetingNotice(_ event: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            Text("下一场《\(event.displayTitle)》\(eventCountdown(event, now: calendar.now)) · 结束当前记录后可开始")
                .lineLimit(1)
            Spacer()
            if let url = event.joinURL { Button("加入会议") { NSWorkspace.shared.open(url) }.buttonStyle(.link) }
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 28).padding(.vertical, 8)
    }

    private func syncFailure(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("日历未同步，临近会议可能未显示：\(message)").lineLimit(2)
            Spacer()
            if calendar.needsReconnect {
                GoogleConnectButton(calendar: calendar, style: .plain)
            } else {
                Button("重试") { Task { await calendar.sync() } }
            }
        }
        .font(.callout)
        .padding(.horizontal, 28).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

/// Shown by generic start entries when calendar meetings are due; never picks one silently.
struct StartChooserSheet: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var calendar: CalendarController
    init(controller: MeetingController) { self.controller = controller; calendar = controller.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("要开始哪场会议？").font(.title3.weight(.semibold))
                Text("这些日程即将开始或正在进行。选择后开始记录，并关联到这场日程。").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 8) { ForEach(controller.startableEvents) { row($0) } }.padding(.horizontal, 24)
            }
            .frame(maxHeight: 340)
            Divider().padding(.top, 14)
            HStack {
                Button { Task { await controller.startMeeting() } } label: { Label("开始临时会议", systemImage: "plus.circle") }
                    .disabled(controller.busy)
                Spacer()
                Button("取消", role: .cancel) { controller.startChooserPresented = false }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560)
        .onChange(of: controller.startableEvents.isEmpty) { _, empty in
            if empty { controller.startChooserPresented = false }
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        let records = controller.records(for: event)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if !records.isEmpty {
                        Text("已有记录").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }
                Text([eventTimeRange(event.start, event.end), eventCountdown(event, now: calendar.now),
                      event.organizer.map { "组织者 \($0.displayName)" } ?? "", calendar.account ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let record = records.first {
                Button("查看记录") { controller.selectedID = record.id; controller.startChooserPresented = false }
                Button("追加记录") { Task { await controller.startMeeting(event: event) } }.disabled(controller.busy)
            } else {
                Button("开始") { Task { await controller.startMeeting(event: event) } }
                    .buttonStyle(.borderedProminent).disabled(controller.busy)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Links an existing record to a calendar occurrence, or corrects or removes the link.
struct CalendarLinkSheet: View {
    @ObservedObject var controller: MeetingController
    let meetingID: UUID
    @Binding var presented: Bool
    @State private var events: [CalendarEvent]?
    @State private var failure: String?

    private var meeting: Meeting? { controller.meetings.first { $0.id == meetingID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting?.calendar == nil ? "关联日历会议" : "更改关联的日历会议").font(.title3.weight(.semibold))
                Text("录音、原文、开始时间和你改过的名称都会保留。已有总结不会被改写。").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            Group {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let events {
                    if events.isEmpty {
                        Text("这次记录前后 12 小时内没有可关联的日程。").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView { VStack(spacing: 8) { ForEach(events) { row($0) } }.padding(.horizontal, 24) }
                    }
                } else {
                    ProgressView("正在读取日历…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 320)
            Divider()
            HStack {
                if meeting?.calendar != nil {
                    Button("取消关联", role: .destructive) { controller.linkMeeting(meetingID, to: nil); presented = false }
                }
                Spacer()
                Button("关闭", role: .cancel) { presented = false }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560)
        .task {
            guard let meeting else { return }
            do { events = try await controller.calendar.events(around: meeting.createdAt) }
            catch { failure = error.localizedDescription }
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        let current = meeting?.calendar?.eventID == event.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text([eventTimeRange(event.start, event.end), event.organizer.map { "组织者 \($0.displayName)" } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if current {
                Label("当前关联", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button("关联") { controller.linkMeeting(meetingID, to: event); presented = false }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One place for the Google connection: the calendar now, mail context later.
struct GoogleAccountSettings: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var calendar: CalendarController
    @State private var confirmDisconnect = false
    init(controller: MeetingController) { self.controller = controller; calendar = controller.calendar }

    var body: some View {
        Form {
            Section {
                if !calendar.configured {
                    Text(GoogleError.notConfigured.localizedDescription).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Label { Text(calendar.account ?? "未连接") } icon: {
                            Image(systemName: calendar.account == nil || calendar.needsReconnect ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(calendar.account == nil || calendar.needsReconnect ? Color.orange : Color.green)
                        }
                        Spacer()
                        GoogleConnectButton(calendar: calendar, style: calendar.account == nil || calendar.needsReconnect ? .prominent : .plain)
                        if calendar.account != nil, !calendar.connecting {
                            Button("断开…", role: .destructive) { confirmDisconnect = true }
                        }
                    }
                    if !calendar.status.isEmpty { Text(calendar.status).font(.caption).textSelection(.enabled) }
                }
            } header: { Text("Google 账号") } footer: {
                Text("使用公司 Google Workspace 账号登录。授权保存在这台 Mac 的钥匙串，不进入会议记录或导出文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if calendar.configured {
                Section {
                    LabeledContent("状态", value: calendar.account == nil ? "未连接" : syncText)
                    LabeledContent("范围", value: "主日历 · 未来 \(Int(CalendarController.range / 86400)) 天 · 只读")
                    LabeledContent("临近会议提醒", value: "开始前 \(Int(CalendarSchedule.lead / 60)) 分钟起，直到日程结束")
                    if calendar.account != nil {
                        Button("立即同步") { Task { await calendar.sync() } }
                            .disabled(calendar.syncState == .syncing || calendar.needsReconnect)
                    }
                } header: { Text("日历") }
                Section {
                    LabeledContent("状态", value: calendar.account == nil ? "未连接" : (calendar.mailAuthorized ? "已授权 · 只读" : "未授权"))
                    if calendar.account != nil, !calendar.mailAuthorized, !calendar.connecting {
                        Button("授权读取邮件") { Task { await calendar.connect() } }
                    }
                } header: { Text("邮件") } footer: {
                    Text("按参会人和会议标题检索近 60–90 天的相关邮件（不含日历通知）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("自动生成", value: "会议开始前 \(Int(BriefSchedule.horizon / 3600)) 小时内；开始前 1 小时补充最新邮件")
                    LabeledContent("会后总结", value: "关联日程的会议对照会前说明，列出变化与未讨论事项")
                } header: { Text("会前说明") } footer: {
                    Text("日历邀请、相关邮件和同一系列的历史总结会用你的 OpenAI Key 发送给 OpenAI 整理。结果保存在这台 Mac；断开 Google 账号时删除缓存，已开始的会议记录保留各自的会前说明。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("断开 Google 账号？", isPresented: $confirmDisconnect) {
            Button("断开", role: .destructive) { Task { await calendar.disconnect() } }; Button("取消", role: .cancel) {}
        } message: { Text("将撤销这台 Mac 上的 Google 授权。已关联的会议记录保持不变。") }
    }

    private var syncText: String {
        switch calendar.syncState {
        case .idle: return "尚未同步"
        case .syncing: return "正在同步…"
        case .synced: return "已同步 · \(calendar.lastSynced?.formatted(date: .omitted, time: .shortened) ?? "")"
        case .failed(let message): return "同步失败：\(message)"
        }
    }
}

/// Connects straight from wherever it appears; the browser does the sign-in.
struct GoogleConnectButton: View {
    enum Style { case prominent, plain, compact }
    @ObservedObject var calendar: CalendarController
    var style: Style = .prominent
    var body: some View {
        if calendar.connecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("等待浏览器授权…").foregroundStyle(.secondary)
                Button("取消") { calendar.cancelConnect() }
            }
        } else {
            let title = calendar.account == nil ? (style == .compact ? "连接" : "连接 Google 账号") : "重新连接"
            if style == .prominent {
                Button(title) { Task { await calendar.connect() } }.buttonStyle(.borderedProminent)
            } else {
                Button(title) { Task { await calendar.connect() } }
            }
        }
    }
}

/// The record's calendar occurrence in the detail header, with linking and appending.
struct CalendarLinkRow: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var calendar: CalendarController
    let meeting: Meeting
    @State private var linking = false
    init(controller: MeetingController, meeting: Meeting) {
        self.controller = controller; self.meeting = meeting; calendar = controller.calendar
    }
    private var canUseCalendar: Bool { calendar.account != nil && !controller.busy }

    var body: some View {
        Group {
            if let link = meeting.calendar {
                HStack(spacing: 10) {
                    Label("日程《\(link.displayTitle)》 \(eventTimeRange(link.scheduledStart, link.scheduledEnd))", systemImage: "calendar.badge.checkmark")
                        .lineLimit(1)
                    if let organizer = link.organizer { Text("组织者 \(organizer.displayName)").lineLimit(1) }
                    if link.account != calendar.account { Text(link.account).lineLimit(1) }
                    // The occurrence is still on: offer an explicit append instead of a duplicate start.
                    if canUseCalendar, link.account == calendar.account, link.scheduledEnd > calendar.now {
                        Button { Task { await controller.appendRecord(to: meeting) } } label: { Label("追加记录", systemImage: "plus.circle") }
                            .buttonStyle(.link)
                    }
                    Menu {
                        Button("更改关联…") { linking = true }.disabled(!canUseCalendar)
                        Button("取消关联") { controller.linkMeeting(meeting.id, to: nil) }.disabled(controller.busy)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("更改或取消关联的日历会议")
                }
                .font(.callout).foregroundStyle(.secondary)
            } else if canUseCalendar {
                Button { linking = true } label: { Label("关联日历会议…", systemImage: "calendar.badge.plus") }
                    .buttonStyle(.link).font(.callout)
            }
        }
        .sheet(isPresented: $linking) { CalendarLinkSheet(controller: controller, meetingID: meeting.id, presented: $linking) }
    }
}

/// Upcoming meetings at the top of the library, or a one-click connection when there is none.
struct CalendarSidebarSection: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var calendar: CalendarController
    let search: String
    static let visible = 6
    init(controller: MeetingController, search: String) {
        self.controller = controller; calendar = controller.calendar; self.search = search
    }

    private var events: [CalendarEvent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let upcoming = controller.upcomingEvents
        return query.isEmpty ? upcoming : upcoming.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        if calendar.configured, search.isEmpty || !events.isEmpty {
            Section {
                if calendar.account == nil || calendar.needsReconnect {
                    connectRow
                } else if events.isEmpty {
                    Text(calendar.syncState == .syncing || calendar.lastSynced == nil ? "正在读取日历…" : "未来 \(Int(CalendarController.range / 86400)) 天没有会议")
                        .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                } else {
                    ForEach(events.prefix(Self.visible)) { event in
                        EventRow(event: event, now: calendar.now, recorded: !controller.records(for: event).isEmpty)
                            .tag(SidebarItem.event(event.id))
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Label("即将开始", systemImage: "calendar")
                    Spacer()
                    if calendar.account != nil, !calendar.needsReconnect, !events.isEmpty {
                        Button(events.count > Self.visible ? "全部 \(events.count) 场" : "全部日程") { controller.calendarSelection = .agenda }
                            .buttonStyle(.link).font(.system(size: 11)).help("按天查看未来 \(Int(CalendarController.range / 86400)) 天的会议")
                    }
                }
            }
        }
    }

    private var connectRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(calendar.needsReconnect ? "Google 授权已失效" : "连接 Google 日历").font(.system(size: 13, weight: .medium))
            Text(calendar.needsReconnect ? "重新连接后继续显示日程。" : "显示接下来的会议，临近时一键开始并自动关联。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GoogleConnectButton(calendar: calendar, style: .prominent).controlSize(.small)
            if !calendar.status.isEmpty, !calendar.connecting {
                Text(calendar.status).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }
}

enum SidebarItem: Hashable { case meeting(UUID), event(String), agenda }

/// Calendar items read as agenda chips — time first, tinted, with a colored edge — so they never look like records.
private struct EventRow: View {
    let event: CalendarEvent
    let now: Date
    let recorded: Bool
    var body: some View {
        let due = !CalendarSchedule.startable([event], at: now).isEmpty
        let tint: Color = due ? (event.start <= now ? .orange : accent) : accent.opacity(0.45)
        HStack(spacing: 9) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.start.formatted(.dateTime.hour().minute())).font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text(due ? dueLabel : eventDay(event.start, now: now, short: true)).font(.system(size: 10))
                    .foregroundStyle(due ? tint : Color.secondary)
            }
            .frame(width: 48, alignment: .leading)
            Text(event.displayTitle).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 0)
            if recorded {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary).help("已有记录")
            } else if event.joinURL != nil {
                Image(systemName: "video").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 8)
        .background(accent.opacity(due ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(event.displayTitle)
    }
    private var dueLabel: String {
        if event.start <= now { return "进行中" }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 1 ? "即将开始" : "\(minutes) 分钟后"
    }
}

/// A calendar occurrence before it has a record: when, who, and how to start it.
struct EventDetailView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var calendar: CalendarController
    @ObservedObject private var audioSetup: BlackHoleSetup
    let event: CalendarEvent
    init(controller: MeetingController, event: CalendarEvent) {
        self.controller = controller; self.event = event
        calendar = controller.calendar; audioSetup = controller.audioSetup
    }

    var body: some View {
        let records = controller.records(for: event)
        let series = controller.seriesRecords(for: event)
        let due = !CalendarSchedule.startable([event], at: calendar.now).isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.displayTitle).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    HStack(spacing: 14) {
                        Label("\(eventDay(event.start, now: calendar.now)) \(event.start.formatted(.dateTime.month().day())) \(eventTimeRange(event.start, event.end))",
                              systemImage: "calendar")
                        Text(eventCountdown(event, now: calendar.now)).foregroundStyle(due ? (event.start <= calendar.now ? Color.orange : accent) : .secondary)
                        if event.recurringEventID != nil { Label("重复会议", systemImage: "repeat") }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button { Task { await controller.startMeeting(event: event) } } label: {
                        Label(records.isEmpty ? "开始《\(buttonTitle(event.displayTitle))》" : "追加记录",
                              systemImage: records.isEmpty ? "record.circle" : "plus.circle").lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(controller.busy || audioSetup.working)
                    if let url = event.joinURL {
                        Button { NSWorkspace.shared.open(url) } label: { Label("加入会议", systemImage: "video") }.controlSize(.large)
                    }
                }
                if !due {
                    Text("开始前 \(Int(CalendarSchedule.lead / 60)) 分钟，主窗口顶部会提醒你开始这场会议。打开会议链接不会开始记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                EventBriefSection(controller: controller, event: event)
                if !records.isEmpty { recordList("本场记录", records) }
                if !event.attendees.isEmpty || event.organizer != nil { invitees }
                if !series.isEmpty { recordList("同一系列的历史记录", Array(series.prefix(5))) }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var invitees: some View {
        let people = event.attendees.isEmpty ? [event.organizer].compactMap { $0 } : event.attendees
        return VStack(alignment: .leading, spacing: 8) {
            Text("受邀人（\(people.count)）").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                    if index > 0 { Divider().padding(.leading, 40) }
                    HStack(spacing: 10) {
                        Image(systemName: Self.icon(person.response)).foregroundStyle(Self.color(person.response)).frame(width: 18)
                            .help(Self.responseName(person.response))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.displayName + (person.isSelf ? "（我）" : "")).font(.system(size: 13))
                            if person.name != nil { Text(person.email).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if person.isOrganizer || person.email == event.organizer?.email {
                            Text("组织者").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(Self.responseName(person.response)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("受邀和回复状态只是背景，不代表实际出席或发言。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func recordList(_ title: String, _ meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                    if index > 0 { Divider().padding(.leading, 12) }
                    Button { controller.selectedID = meeting.id } label: {
                        HStack(spacing: 8) {
                            Text(meeting.title).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            Text(meeting.createdAt.formatted(.dateTime.month().day().hour().minute())).font(.caption).foregroundStyle(.secondary)
                            let duration = durationText(meeting.duration)
                            if !duration.isEmpty { Text(duration).font(.caption).foregroundStyle(.secondary) }
                            StateBadge(state: meeting.state)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                    .buttonStyle(.plain).disabled(controller.busy)
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    static func responseName(_ response: String?) -> String {
        ["accepted": "已接受", "declined": "已拒绝", "tentative": "待定", "needsAction": "未回复"][response ?? ""] ?? "未回复"
    }
    static func icon(_ response: String?) -> String {
        ["accepted": "checkmark.circle.fill", "declined": "xmark.circle.fill", "tentative": "questionmark.circle.fill"][response ?? ""] ?? "circle.dashed"
    }
    static func color(_ response: String?) -> Color {
        ["accepted": Color.green, "declined": Color.red, "tentative": Color.orange][response ?? ""] ?? Color.secondary
    }
}

/// Every upcoming meeting in the synced week, by day.
struct AgendaView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var calendar: CalendarController
    init(controller: MeetingController) { self.controller = controller; calendar = controller.calendar }

    var body: some View {
        let days = Dictionary(grouping: controller.upcomingEvents) { Calendar.current.startOfDay(for: max($0.start, calendar.now)) }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未来 \(Int(CalendarController.range / 86400)) 天的会议").font(.system(size: 22, weight: .semibold))
                        Text([calendar.account ?? "", calendar.lastSynced.map { "已同步 \($0.formatted(date: .omitted, time: .shortened))" } ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即同步") { Task { await calendar.sync() } }.disabled(calendar.syncState == .syncing || calendar.needsReconnect)
                }
                ForEach(days.keys.sorted(), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dayTitle(day)).font(.headline)
                        VStack(spacing: 0) {
                            ForEach(Array((days[day] ?? []).enumerated()), id: \.element.id) { index, event in
                                if index > 0 { Divider().padding(.leading, 12) }
                                Button { controller.calendarSelection = .event(event.id) } label: { row(event) }.buttonStyle(.plain)
                            }
                        }
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.month().day().weekday(.wide))
        let relative = eventDay(day, now: calendar.now)
        return relative == "今天" || relative == "明天" ? "\(relative) · \(date)" : date
    }

    private func row(_ event: CalendarEvent) -> some View {
        // The day heading carries the date; rows show only the times.
        let time = event.start.formatted(.dateTime.hour().minute()) + "–" + event.end.formatted(.dateTime.hour().minute())
        return HStack(spacing: 12) {
            Text(time).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                let invitees = inviteeSummary(event.attendees, organizer: event.organizer)
                if !invitees.isEmpty { Text(invitees).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if !controller.records(for: event).isEmpty { Text("已记录").font(.caption).foregroundStyle(.secondary) }
            if event.joinURL != nil { Image(systemName: "video").foregroundStyle(.tertiary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
