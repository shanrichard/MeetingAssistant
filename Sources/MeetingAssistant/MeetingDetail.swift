import SwiftUI
import MeetingCore

enum DetailTab: Hashable { case brief, summary, transcript }

struct MeetingDetailView: View {
    @ObservedObject var controller: MeetingController
    let meeting: Meeting
    let rename: () -> Void
    let delete: () -> Void
    @State private var tab: DetailTab = .transcript
    @State private var search = ""
    @State private var evidenceID: String?
    @State private var transcriptSource: TranscriptSource?
    @State private var showingBrief = false

    private var isLive: Bool { controller.recording && (controller.liveMeeting?.id ?? meeting.id) == meeting.id }
    private var hasLiveText: Bool { meeting.liveSegments.contains(where: \.hasText) }

    var body: some View {
        VStack(spacing: 0) {
            if isLive { LiveControlBar(controller: controller, overlay: controller.captionOverlay) }
            if controller.processing || (controller.starting && !controller.recording) { progressBanner }
            if isLive { liveTranscript } else { header; Divider(); content }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { controller.export() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .help("导出为 Markdown").disabled(controller.busy)
                Menu {
                    Button("重命名…", action: rename)
                    Button("在 Finder 中显示") { controller.revealInFinder(meeting.id) }
                    Divider()
                    Button("删除会议…", role: .destructive, action: delete)
                } label: { Label("更多", systemImage: "ellipsis.circle") }
                    .disabled(controller.busy)
            }
        }
        .onAppear { tab = meeting.summary == nil ? .transcript : .summary }
        .onChange(of: meeting.id) { _, _ in
            tab = meeting.summary == nil ? .transcript : .summary
            transcriptSource = nil; evidenceID = nil; search = ""
        }
        // A summary finished after the meeting ended is what people look for next.
        .onChange(of: meeting.summary == nil) { _, missing in if !missing { tab = .summary } }
    }

    private var progressBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(controller.status).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(accent.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                    .onTapGesture(count: 2) { if !controller.busy { rename() } }
                    .help("双击重命名")
                HStack(spacing: 14) {
                    Label(meeting.createdAt.formatted(.dateTime.month().day().weekday().hour().minute()), systemImage: "calendar")
                    let duration = durationText(meeting.duration)
                    if !duration.isEmpty { Label(duration, systemImage: "clock") }
                    Label("字幕 \(AppPreferences.languageName(meeting.subtitleLanguage)) · 对外 \(AppPreferences.languageName(meeting.outgoingLanguage))",
                          systemImage: "globe")
                    StateBadge(state: meeting.state)
                }
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                CalendarLinkRow(controller: controller, meeting: meeting)
            }
            HStack(spacing: 12) {
                Picker("内容", selection: $tab) {
                    if meeting.brief != nil { Text("会前说明").tag(DetailTab.brief) }
                    Text("会议总结").tag(DetailTab.summary)
                    Text("对话全文").tag(DetailTab.transcript)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if tab == .transcript, !meeting.finalSegments.isEmpty {
                    Picker("记录来源", selection: Binding(get: { transcriptSource ?? meeting.defaultTranscriptSource },
                                                         set: { transcriptSource = $0; evidenceID = nil })) {
                        Text("实时原文（\(meeting.liveSegments.count) 段）").tag(TranscriptSource.live)
                        Text("历史转写（\(meeting.finalSegments.count) 段）").tag(TranscriptSource.recording)
                    }
                    .labelsHidden().fixedSize()
                    .help("总结仅使用实时原文。历史转写独立保留。")
                }
                Spacer()
                if tab == .transcript {
                    SearchField(text: $search, prompt: "搜索发言").frame(width: 210)
                } else if meeting.summary != nil, !controller.busy {
                    Button { Task { await controller.updateSummary() } } label: { Label("更新总结", systemImage: "arrow.clockwise") }
                        .disabled(!hasLiveText)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
    }

    @ViewBuilder private var content: some View {
        if tab == .brief, let brief = meeting.brief {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(briefFooter(brief) + " · 会议开始时的版本").font(.caption).foregroundStyle(.secondary)
                    BriefView(brief: brief, openMeeting: { controller.selectedID = $0 })
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        } else if tab == .summary {
            summary
        } else {
            TranscriptTimeline(segments: meeting.segments(from: transcriptSource ?? meeting.defaultTranscriptSource), meeting: meeting,
                               isLive: false, search: search, evidenceID: evidenceID, notices: meeting.notices)
                .id(meeting.id)
        }
    }

    private var liveTranscript: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("实时字幕").font(.headline)
                Text(AppPreferences.languageName(meeting.subtitleLanguage)).font(.caption.weight(.medium)).foregroundStyle(accent)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(accent.opacity(0.12), in: Capsule())
                Spacer()
                if let brief = meeting.brief {
                    // The brief stays at hand during the meeting without leaving the live captions.
                    Button { showingBrief.toggle() } label: { Label("会前说明", systemImage: "doc.text.magnifyingglass") }
                        .popover(isPresented: $showingBrief, arrowEdge: .bottom) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(briefFooter(brief)).font(.caption).foregroundStyle(.secondary)
                                    BriefView(brief: brief)
                                }
                                .padding(18)
                            }
                            .frame(width: 480, height: 520)
                        }
                }
                SearchField(text: $search, prompt: "搜索发言").frame(width: 210)
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            TranscriptTimeline(segments: meeting.segments(from: .live), meeting: meeting,
                               isLive: true, search: search, evidenceID: nil, notices: meeting.notices)
                .id(meeting.id)
        }
    }

    @ViewBuilder private var summary: some View {
        if let summary = meeting.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if meeting.summaryUsesDifferentTranscript {
                        Label(hasLiveText ? "这份历史总结引用了旧版转写。更新总结将仅使用实时原文。" : "这份历史总结引用了旧版转写。本场没有可用于重新总结的实时原文。",
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    SummarySection(title: "会议概要", icon: "text.alignleft", points: summary.overview, marker: .dot, meeting: meeting, open: openEvidence)
                    SummarySection(title: "已作出的决策", icon: "checkmark.seal", points: summary.decisions, marker: .check, meeting: meeting, open: openEvidence)
                    SummarySection(title: "待办事项", icon: "checklist", points: summary.actions, marker: .todo, meeting: meeting, open: openEvidence)
                    SummarySection(title: "待确认的问题", icon: "questionmark.bubble", points: summary.questions, marker: .dot, meeting: meeting, open: openEvidence)
                    if let changes = summary.changes, !changes.isEmpty {
                        ContextSummarySection(title: "相对会前的变化", icon: "arrow.triangle.branch", points: changes, meeting: meeting,
                                              open: openEvidence, openMeeting: { controller.selectedID = $0 })
                    }
                    if let unaddressed = summary.unaddressed, !unaddressed.isEmpty {
                        ContextSummarySection(title: "会前事项未讨论", icon: "tray", points: unaddressed, meeting: meeting,
                                              open: openEvidence, openMeeting: { controller.selectedID = $0 })
                    }
                    Text(summary.changes == nil ? "根据实时原文生成。点击条目右侧的引用图标可查看原文。"
                         : "根据实时原文生成，并对照会前说明。变化须有本次原文支持；来源标签指向邮件、日历或之前的会议。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label(hasLiveText ? "尚未生成会议总结" : "没有可总结的实时原文", systemImage: "text.badge.checkmark")
            } description: {
                Text(hasLiveText ? "直接使用已有实时原文，提炼概要、决策、待办和待确认的问题。每条附有原文引用。" : "本场录音仍保存在这台 Mac。")
            } actions: {
                if hasLiveText {
                    Button("生成总结") { Task { await controller.updateSummary() } }
                        .buttonStyle(.borderedProminent).disabled(controller.busy)
                }
            }
        }
    }

    private func openEvidence(_ id: String) {
        search = ""; tab = .transcript; evidenceID = nil
        transcriptSource = meeting.transcriptSource(forEvidence: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { evidenceID = id }
    }
}

private struct SummarySection: View {
    enum Marker { case dot, check, todo }
    let title: String
    let icon: String
    let points: [SummaryPoint]
    let marker: Marker
    let meeting: Meeting
    let open: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(accent)
                Text(title).font(.headline)
                if !points.isEmpty {
                    Text("\(points.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
                }
            }
            if points.isEmpty { Text("未记录明确内容").font(.callout).foregroundStyle(.tertiary) }
            ForEach(points) { point in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    markerView
                    Text(point.text).textSelection(.enabled).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !point.evidence.isEmpty {
                        SummaryEvidenceButton(point: point, meeting: meeting, open: open)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    @ViewBuilder private var markerView: some View {
        switch marker {
        case .dot: Circle().fill(accent).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
        case .check: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
        case .todo: Image(systemName: "circle").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

struct SummaryEvidenceButton: View {
    let point: SummaryPoint
    let meeting: Meeting
    let open: (String) -> Void
    @State private var showingEvidence = false

    var body: some View {
        Button { showingEvidence.toggle() } label: {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看原文引用（\(point.evidence.count) 处）")
        .accessibilityLabel("查看原文引用")
        .accessibilityValue("\(point.evidence.count) 处")
        .accessibilityHint(point.text)
        .popover(isPresented: $showingEvidence, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("原文引用").font(.headline)
                    Spacer()
                    Text("\(point.evidence.count) 处").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(point.evidence.enumerated()), id: \.offset) { index, id in
                            if index > 0 { Divider() }
                            if let segment = meeting.liveSegments.first(where: { $0.id == id }) ?? meeting.finalSegments.first(where: { $0.id == id }) {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 8) {
                                        Text(timestamp(segment.start)).monospacedDigit()
                                        Text(meeting.speaker(for: segment))
                                        Spacer()
                                        Button {
                                            showingEvidence = false
                                            open(id)
                                        } label: {
                                            Label("查看上下文", systemImage: "arrow.up.right")
                                        }
                                        .buttonStyle(.link)
                                        .accessibilityLabel("查看 \(timestamp(segment.start)) 的对话上下文")
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                    Text(segment.text).font(.callout).textSelection(.enabled)
                                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                Text("这处原文已不可用").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(width: 380)
        }
    }
}

struct LiveControlBar: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject var overlay: CaptionOverlay
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RecordingDot(paused: controller.paused, elapsed: controller.elapsed, size: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(controller.paused ? "已暂停" : "正在记录").font(.caption.weight(.semibold))
                        .foregroundStyle(controller.paused ? Color.orange : Color.red)
                    Text(timestamp(controller.elapsed)).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                }
                Spacer(minLength: 16)
                Toggle(isOn: Binding(get: { overlay.visible }, set: { $0 ? overlay.show() : overlay.hide() })) {
                    Label("悬浮字幕", systemImage: "captions.bubble")
                }
                .toggleStyle(.button)
                .help(overlay.visible ? "隐藏悬浮字幕" : "在会议窗口上方显示半透明字幕")
                voiceButton.disabled(controller.paused)
                Button { controller.togglePause() } label: {
                    Label(controller.paused ? "继续" : "暂停", systemImage: controller.paused ? "play.fill" : "pause.fill")
                }
                Button { Task { await controller.finishMeeting() } } label: { Label("结束会议", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
            .controlSize(.large)
            HStack(alignment: .top, spacing: 24) {
                AudioLevelView(levels: controller.audioLevels, source: .microphone, detail: controller.micState)
                AudioLevelView(levels: controller.audioLevels, source: .system, detail: controller.systemState)
                Spacer(minLength: 12)
                voiceStatus
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color.red.opacity(controller.paused ? 0 : 0.035))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var voiceButton: some View {
        if controller.voiceNeedsRouteRestore {
            Button { controller.toggleVoice() } label: { Label("恢复原麦克风", systemImage: "mic.fill") }
                .buttonStyle(.borderedProminent).tint(.orange)
        } else {
            Toggle(isOn: Binding(get: { controller.sendingVoice }, set: { _ in controller.toggleVoice() })) {
                Label(controller.sendingVoice ? "正在发送译音" : "发送我的译音", systemImage: "waveform")
            }
            .toggleStyle(.button)
            .help("把你的发言实时翻译成语音，通过虚拟麦克风送入会议")
        }
    }

    private var voiceStatus: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if controller.sendingVoice || controller.voiceNeedsRouteRestore {
                Text(controller.voiceState).foregroundStyle(controller.sendingVoice ? accent : Color.orange)
                Text(controller.voiceRouteState).foregroundStyle(.secondary)
                Text("会议软件的静音与本助手独立").foregroundStyle(.tertiary)
            } else {
                Text("建议佩戴耳机").foregroundStyle(.secondary)
                Text(controller.voiceRouteState).foregroundStyle(.tertiary)
            }
        }
        .font(.caption).multilineTextAlignment(.trailing).lineLimit(2)
    }
}

private struct AudioLevelView: View {
    @ObservedObject var levels: AudioLevels
    let source: AudioSource
    let detail: String
    private var level: Double { source == .microphone ? levels.microphone : levels.system }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: source == .microphone ? "mic.fill" : "speaker.wave.2.fill").foregroundStyle(.secondary).frame(width: 14)
                Text(source == .microphone ? "麦克风" : "系统声音").fontWeight(.medium)
                LevelMeter(level: level, width: 72)
            }
            .font(.caption)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(detail)
        }
        .frame(width: 200, alignment: .leading)
    }
}
