import SwiftUI
import MeetingCore

/// A brief's sections; every point carries the sources it came from.
struct BriefView: View {
    let brief: MeetingBrief
    var openMeeting: ((UUID) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if brief.isEmpty {
                Text("没有找到与这场会议相关的往来或历史结论。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(brief.sections.filter { !$0.points.isEmpty }, id: \.title) { section in
                VStack(alignment: .leading, spacing: 9) {
                    Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(point.text).textSelection(.enabled).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                SourceChips(ids: point.sources, brief: brief, openMeeting: openMeeting)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SourceChips: View {
    let ids: [String]
    let brief: MeetingBrief?
    var openMeeting: ((UUID) -> Void)?
    var body: some View {
        let sources = ids.compactMap { brief?.source($0) }
        if !sources.isEmpty {
            HStack(spacing: 6) {
                ForEach(sources.prefix(3)) { SourceChip(source: $0, openMeeting: openMeeting) }
                if sources.count > 3 { Text("+\(sources.count - 3)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct SourceChip: View {
    let source: BriefSource
    var openMeeting: ((UUID) -> Void)?
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Label(buttonTitle(source.title, limit: 24), systemImage: Self.icon(source.kind)).lineLimit(1).font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help("查看来源")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label(Self.kindName(source.kind), systemImage: Self.icon(source.kind)).font(.caption).foregroundStyle(.secondary)
                Text(source.title).font(.headline).textSelection(.enabled)
                Text([source.detail, source.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let excerpt = source.excerpt, !excerpt.isEmpty {
                    Text(excerpt).font(.callout).textSelection(.enabled).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                if let link = source.link {
                    Button { NSWorkspace.shared.open(link) } label: { Label("在 Gmail 中打开", systemImage: "arrow.up.right") }.buttonStyle(.link)
                }
                if let id = source.meetingID, let openMeeting {
                    Button { showing = false; openMeeting(id) } label: { Label("打开这次记录", systemImage: "arrow.up.right") }.buttonStyle(.link)
                }
            }
            .padding(16).frame(width: 360, alignment: .leading)
        }
    }
    static func icon(_ kind: BriefSource.Kind) -> String {
        switch kind { case .calendar: return "calendar"; case .email: return "envelope"; case .meeting: return "doc.text" }
    }
    static func kindName(_ kind: BriefSource.Kind) -> String {
        switch kind { case .calendar: return "日历邀请"; case .email: return "邮件"; case .meeting: return "之前的会议" }
    }
}

func briefFooter(_ brief: MeetingBrief) -> String {
    var parts = ["生成于 \(brief.generatedAt.formatted(date: .omitted, time: .shortened))"]
    let mail = brief.count(.email), history = brief.count(.meeting)
    if mail > 0 { parts.append("参考 \(mail) 个邮件往来") }
    if history > 0 { parts.append("\(history) 场历史会议") }
    if !brief.mailIncluded { parts.append("未读取邮件") }
    return parts.joined(separator: " · ")
}

/// The brief for one upcoming meeting, generated automatically; shown on the event page.
struct EventBriefSection: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var briefs: BriefController
    @ObservedObject private var calendar: CalendarController
    let event: CalendarEvent
    init(controller: MeetingController, event: CalendarEvent) {
        self.controller = controller; self.event = event; briefs = controller.briefs; calendar = controller.calendar
    }

    var body: some View {
        if BriefSchedule.isBriefable(event) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(accent)
                    Text("会前说明").font(.headline)
                    Spacer()
                    if let brief = briefs.brief(for: event.id), briefs.states[event.id] != .generating {
                        Text(briefFooter(brief)).font(.caption).foregroundStyle(.secondary)
                        Button { Task { await briefs.generate(event) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("重新整理").disabled(!controller.hasKey)
                    }
                }
                content
                if calendar.account != nil, !calendar.mailAuthorized, controller.hasKey {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.badge").foregroundStyle(.orange)
                        Text("未授权读取邮件，会前说明只参考日历和历史记录。").font(.caption).foregroundStyle(.secondary)
                        Button("授权读取邮件") { Task { await calendar.connect() } }.buttonStyle(.link).font(.caption).disabled(calendar.connecting)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // A brief already prepared stays readable even if the key was removed later.
    @ViewBuilder private var content: some View {
        if briefs.states[event.id] == .generating {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(calendar.mailAuthorized ? "正在根据日历、相关邮件和历史记录整理…" : "正在根据日历和历史记录整理…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let brief = briefs.brief(for: event.id) {
            BriefView(brief: brief, openMeeting: { controller.selectedID = $0 })
        } else if !controller.hasKey {
            HStack(spacing: 8) {
                Text("保存 OpenAI API Key 后，会议开始前会自动生成会前说明。").font(.callout).foregroundStyle(.secondary)
                SettingsDestinationLink(tab: "general") { Text("设置") }
            }
        } else if case .failed(let message) = briefs.states[event.id] {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("会前说明未生成：\(message)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("重试") { Task { await briefs.generate(event) } }
            }
        } else {
            HStack(spacing: 8) {
                Text("会议开始前 \(Int(BriefSchedule.horizon / 3600)) 小时内会自动生成。").font(.callout).foregroundStyle(.secondary)
                Button("现在生成") { Task { await briefs.generate(event) } }
            }
        }
    }
}

/// Summary points read against the brief: transcript evidence plus the background they relate to.
struct ContextSummarySection: View {
    let title: String
    let icon: String
    let points: [ContextPoint]
    let meeting: Meeting
    let open: (String) -> Void
    var openMeeting: ((UUID) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(accent)
                Text(title).font(.headline)
                Text("\(points.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
            }
            ForEach(points) { point in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(point.text).textSelection(.enabled).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        SourceChips(ids: point.background, brief: meeting.brief, openMeeting: openMeeting)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !point.evidence.isEmpty {
                        SummaryEvidenceButton(point: SummaryPoint(text: point.text, evidence: point.evidence), meeting: meeting, open: open)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
