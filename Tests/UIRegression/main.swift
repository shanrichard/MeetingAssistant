import SwiftUI
import MeetingCore

// Render the production views with synthetic state, without starting capture or API work.
@MainActor final class RegressionState: ObservableObject {
    @Published var previewAudioSetup = false
    let controller: MeetingController
    private let folder: URL
    init() {
        if CommandLine.arguments.contains("--check-captions") {
            do { try checkCaptionDisplay(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--check-audio-levels") {
            do { try checkAudioLevelIsolation(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingUIRegression-" + UUID().uuidString)
        controller = MeetingController(storageRoot: folder, calendar: offlineCalendar())
    }
    func show(_ state: String) {
        controller.starting = state == "preparing"
        controller.recording = state == "recording"
        controller.processing = state == "processing"
        controller.paused = false
        controller.status = "离线界面测试"
        var meeting = Meeting(title: "离线测试会议")
        meeting.state = state
        do { try MeetingStore(root: folder).save(meeting) }
        catch { controller.error = error.localizedDescription }
        controller.meetings = [meeting]
        controller.selectedID = meeting.id
        controller.micLevel = 0.35
        controller.systemLevel = 0.7
    }
    static let dialogue: [(AudioSource, String, String)] = [
        (.system, "Can everyone see my screen?", "大家能看到我的屏幕吗？"),
        (.microphone, "可以看到，请继续。", "可以看到，请继续。"),
        (.system, "Great. Let's start with the beta timeline.", "好的，我们先看测试版的时间表。"),
        (.system, "We think we can ship the beta next Friday, if QA signs off by Wednesday.", "如果测试团队周三前确认，我们认为下周五可以发布测试版。"),
        (.microphone, "周三之前我们可以完成回归测试。", "周三之前我们可以完成回归测试。"),
        (.system, "Perfect. The other open item is pricing for the enterprise tier.", "很好。另一个待定事项是企业版的定价。"),
        (.system, "Can your team share the usage numbers from last quarter?", "你们团队能分享一下上季度的使用数据吗？"),
        (.microphone, "可以，我会后发给你。", "可以，我会后发给你。"),
    ]
    func captions(complete: Bool = false) {
        show(complete ? "complete" : "recording")
        var meeting = controller.meetings[0]
        let segments: [TranscriptSegment] = (0..<32).map { index -> TranscriptSegment in
            let sample = Self.dialogue[index % Self.dialogue.count]
            return TranscriptSegment(id: "sample-\(index)", source: sample.0,
                start: Double(index * 6), end: Double(index * 6 + 5), text: sample.1,
                translation: sample.2, isFinal: true)
        }
        meeting.liveSegments = segments
        if complete { meeting.finalSegments = segments; meeting.duration = 32 * 6 }
        controller.meetings = [meeting]
        controller.elapsed = 32 * 6
        controller.translationStates = [.microphone: "实时同传已连接", .system: "实时同传已连接"]
        controller.micState = "实时同传已连接"; controller.systemState = "实时同传已连接"
    }
    /// A library spanning several days, with the newest meeting summarized.
    func library() {
        captions(complete: true)
        controller.recording = false
        var latest = controller.meetings[0]
        latest.title = "产品周会：测试版发布计划"
        latest.subtitleLanguage = "zh"; latest.outgoingLanguage = "en"
        latest.summary = MeetingSummary(
            overview: [.init(text: "对齐测试版发布时间表与企业版定价两项议题；测试团队周三前确认后，下周五发布测试版。", evidence: ["sample-2", "sample-3"])],
            decisions: [.init(text: "测试版目标发布日期定为下周五，前提是周三前完成回归测试。", evidence: ["sample-3", "sample-4"])],
            actions: [.init(text: "我方在周三前完成回归测试并同步结果。", evidence: ["sample-4"]),
                      .init(text: "会后发送上季度的使用数据，用于企业版定价。", evidence: ["sample-7"])],
            questions: [.init(text: "企业版的定价区间尚未确定，需要使用数据后再讨论。", evidence: ["sample-5"])])
        let calendar = Calendar.current, now = Date()
        func meeting(_ title: String, daysAgo: Int, minutes: Double, state: String = "complete") -> Meeting {
            var item = Meeting(title: title)
            item.createdAt = calendar.date(byAdding: .day, value: -daysAgo, to: now)!.addingTimeInterval(-Double(daysAgo) * 3700)
            item.duration = minutes * 60; item.state = state
            return item
        }
        controller.meetings = [latest, meeting("设计评审：悬浮字幕", daysAgo: 0, minutes: 38),
                               meeting("与 Acme 的合作沟通", daysAgo: 1, minutes: 52, state: "recorded"),
                               meeting("Weekly sync with Berlin team", daysAgo: 3, minutes: 47),
                               meeting("招聘面试 · 后端工程师", daysAgo: 12, minutes: 61),
                               meeting("Q4 规划", daysAgo: 40, minutes: 95)]
        controller.selectedID = latest.id
    }
    func welcome() {
        show("complete")
        controller.meetings = []; controller.selectedID = nil
        controller.calendar.preview(account: nil, events: [])
    }
    /// A calendar meeting a few minutes away, plus an overlapping one, while the library is open.
    func calendarDue(overlapping: Bool = false, linked: Bool = false, week: Bool = false) {
        library()
        let now = Date()
        var events = [sampleEvent("weekly", "产品周会：测试版发布计划", start: 4, end: 34, now: now, series: "weekly-series")]
        if overlapping { events.append(sampleEvent("client", "Acme 合作沟通", start: -5, end: 25, now: now, join: false)) }
        if week {
            let day = 24.0 * 60
            events += [sampleEvent("design", "设计评审：日程入口", start: 150, end: 195, now: now),
                       sampleEvent("standup", "研发站会", start: day + 30, end: day + 45, now: now, series: "standup"),
                       sampleEvent("berlin", "Weekly sync with Berlin team", start: day + 300, end: day + 345, now: now),
                       sampleEvent("pricing", "企业版定价讨论", start: 2 * day + 120, end: 2 * day + 180, now: now, join: false),
                       sampleEvent("hiring", "招聘面试 · 后端工程师", start: 3 * day + 60, end: 3 * day + 120, now: now),
                       sampleEvent("q4", "Q4 规划", start: 5 * day + 90, end: 5 * day + 210, now: now)]
            // An earlier occurrence of the weekly meeting already has a record.
            if let link = controller.calendar.link(for: sampleEvent("weekly_prev", "产品周会：测试版发布计划", start: -7 * day + 4, end: -7 * day + 34,
                                                                    now: now, series: "weekly-series")) {
                controller.meetings[0].link(link)
            }
        }
        controller.calendar.preview(account: "me@example.com", events: events, now: now)
        controller.briefs.preview(week ? [sampleBrief("weekly", earlier: controller.meetings[0].id)] : [],
                                  states: week ? ["standup": .generating] : [:])
        if linked, let link = controller.calendar.link(for: sampleEvent("past", "设计评审：悬浮字幕", start: -50, end: 10, now: now)) {
            controller.meetings[0].link(link); controller.meetings[0].title = "设计评审：悬浮字幕"
        }
    }
    /// A summarized record read against its brief.
    func contextSummary() {
        library()
        var meeting = controller.meetings[0]
        meeting.brief = sampleBrief("weekly")
        meeting.summary?.changes = [ContextPoint(text: "测试版发布日期确认为下周五，与邮件中的提议一致；前提改为周三前完成回归测试。",
                                                 evidence: ["sample-3", "sample-4"], background: ["email:t1"])]
        meeting.summary?.unaddressed = [ContextPoint(text: "企业版是否采用定价草案 v2 未讨论，仍待使用数据后决定。", evidence: ["sample-5"], background: ["email:t2"])]
        controller.meetings[0] = meeting
    }
    func calendarRecording() {
        captions()
        let now = Date()
        controller.calendar.preview(account: "me@example.com", events: [sampleEvent("next", "季度规划", start: 3, end: 63, now: now)], now: now)
    }
    func calendarOffline() {
        library()
        controller.calendar.preview(account: "me@example.com", events: [], syncState: .failed("网络连接已中断。"))
    }
    func append(translation: Bool = false, grow: Bool = false) {
        guard !controller.meetings.isEmpty else { return }
        if translation {
            guard let index = controller.meetings[0].liveSegments.indices.last else { return }
            controller.meetings[0].liveSegments[index].translation = "请确认下周的会议时间。"
        } else if grow, let index = controller.meetings[0].liveSegments.indices.last {
            controller.meetings[0].liveSegments[index].text += " This is an incremental update to the SAME utterance, testing text wrapping and automatic scrolling."
        } else {
            let index = controller.meetings[0].liveSegments.count
            controller.meetings[0].liveSegments.append(.init(id: "added-source-\(index)", source: .system,
                start: Double(index * 4), end: Double(index * 4 + 3), text: "Please confirm the next meeting.", isFinal: false))
        }
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
}

@main struct MeetingUIRegressionApp: App {
    @StateObject private var state = RegressionState()
    init() {
        if CommandLine.arguments.contains("--check-summary") {
            Task { @MainActor in
                do { try await checkSummaryPreservation(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--check-calendar") {
            Task { @MainActor in
                do { try await checkCalendarFlow(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--check-deletion") {
            do { try checkMeetingDeletion(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--preview-blackhole") {
                BlackHolePreview()
            } else {
            VStack(spacing: 0) {
                // Snapshots show the window exactly as the app lays it out, without these test buttons.
                if SnapshotRunner.folder == nil { HStack {
                    Text("离线回归：不录音、不联网").font(.caption)
                    Button("准备界面") { state.show("preparing") }
                    Button("录音界面") { state.show("recording") }
                    Button("空记录界面") { state.show("recorded") }
                    Button("总结界面") { state.show("processing") }
                    Button("错误提示") { state.controller.error = "离线测试错误：音频设备不可用" }
                    Button("实时字幕") { state.captions() }
                    Button("追加原文") { state.append() }
                    Button("同段增长") { state.append(grow: true) }
                    Button("追加译文") { state.append(translation: true) }
                    Button("会后全文") { state.captions(complete: true) }
                    Button("会议列表") { state.library() }
                    Button("欢迎页") { state.welcome() }
                    Button("临近日程") { state.calendarDue(overlapping: true) }
                    Button("录制中下一场") { state.calendarRecording() }
                    Button("悬浮字幕") {
                        let overlay = state.controller.captionOverlay
                        overlay.toggle()
                        // Focus the non-activating panel so native UI tools can inspect and drag it.
                        if overlay.visible { NSApp.windows.first(where: { $0 is CaptionPanel })?.makeKeyAndOrderFront(nil) }
                    }
                    Button("安装引导") { state.previewAudioSetup = true }
                }.padding(10) }
                ContentView(controller: state.controller)
            }.frame(minWidth: SnapshotRunner.folder == nil ? 1100 : 980, minHeight: SnapshotRunner.folder == nil ? 760 : 640)
                .task { if let folder = SnapshotRunner.folder { await SnapshotRunner.run(state, to: folder) } }
                .sheet(isPresented: $state.previewAudioSetup) { BlackHolePreview() }
            }
        }
    }
}
