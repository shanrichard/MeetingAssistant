import SwiftUI
import MeetingCore

let accent = Color(red: 0.1, green: 0.48, blue: 0.43)

struct ContentView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var audioSetup: BlackHoleSetup
    @State private var tab = "transcript"
    @State private var search = ""
    @State private var evidenceID: String?
    @State private var transcriptSource: TranscriptSource?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var pendingDeletion: Meeting?
    init(controller: MeetingController) {
        self.controller = controller
        audioSetup = controller.audioSetup
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 32)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) { Text("Meeting Assistant").font(.headline); Text("会议助手").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 18)
                Button { Task { await controller.startMeeting() } } label: {
                    Label(controller.starting ? "正在准备…" : "开始新会议", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).tint(accent).disabled(controller.busy || audioSetup.working)
                Text("会议记录").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                List(selection: $controller.selectedID) {
                    ForEach(controller.meetings) { meeting in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack {
                                Text(meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
                                Spacer(); Text(meeting.state == "complete" ? timestamp(meeting.duration) : stateName(meeting.state))
                            }.font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).tag(meeting.id)
                            .contextMenu {
                                Button("删除会议…", role: .destructive) { pendingDeletion = meeting }
                                    .disabled(controller.busy)
                            }
                    }
                }.listStyle(.sidebar).padding(.horizontal, -12).disabled(controller.busy)
                Spacer(minLength: 0)
                HStack {
                    SettingsLink { Label("设置", systemImage: "gearshape") }
                    Spacer()
                    Circle().fill(controller.hasKey ? accent : .orange).frame(width: 6, height: 6)
                    Text(controller.hasSavedKey ? "Key 已保存" : "请设置 Key").font(.caption2).foregroundStyle(.secondary)
                }.padding(.bottom, 12)
            }.padding(.horizontal, 20)
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 290)
        } detail: {
            VStack(spacing: 0) {
                header
                if controller.recording { recordingBar }
                if controller.processing || controller.starting {
                    HStack { ProgressView().controlSize(.small); Text(controller.status).font(.callout); Spacer() }
                        .padding(16).background(accent.opacity(0.06))
                }
                Divider()
                if let meeting = controller.current {
                    meetingBody(meeting)
                } else { welcome }
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .sheet(isPresented: $audioSetup.presented) { BlackHoleSetupView(setup: audioSetup) }
        .sheet(isPresented: $controller.needsKeySetup) {
            VStack(spacing: 0) {
                HStack { Text("设置 API Key").font(.headline); Spacer(); Button("完成") { controller.needsKeySetup = false } }.padding(20)
                SettingsView(controller: controller)
            }.frame(width: 630, height: 690)
        }
        .alert("需要注意", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("知道了") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
        .alert("修改会议名称", isPresented: $editingTitle) {
            TextField("会议名称", text: $titleDraft)
            Button("保存") { controller.renameMeeting(titleDraft) }; Button("取消", role: .cancel) {}
        }
        .alert("删除会议？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { meeting in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) { controller.deleteMeeting(meeting.id); pendingDeletion = nil }
                .disabled(controller.busy)
        } message: { meeting in
            Text("将永久删除“\(meeting.title)”的本地录音、转写全文、译文和总结。此操作无法撤销，已导出的文件不受影响。")
        }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.current?.title ?? "你的会议工作台").font(.system(size: 18, weight: .semibold))
                Text(controller.recording ? "\(timestamp(controller.elapsed)) · \(controller.status)" : "字幕 · 翻译 · 会议全文")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.current != nil, !controller.busy {
                Button { titleDraft = controller.current?.title ?? ""; editingTitle = true } label: { Image(systemName: "pencil") }.help("修改会议名称")
                Button { controller.export() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { pendingDeletion = controller.current } label: { Label("删除", systemImage: "trash") }
                    .help("删除这场会议及其本地录音")
            }
            if controller.recording {
                Button(controller.paused ? "继续记录" : "暂停") { controller.togglePause() }
                Button("结束会议") { Task { await controller.finishMeeting() } }.buttonStyle(.borderedProminent).tint(.red)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
    private var recordingBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                AudioLevelView(levels: controller.audioLevels, source: .microphone, detail: controller.micState)
                AudioLevelView(levels: controller.audioLevels, source: .system, detail: controller.systemState)
                Spacer()
                Button { controller.toggleVoice() } label: {
                    Label(controller.sendingVoice ? "停止发送译音" : "发送我的译音", systemImage: controller.sendingVoice ? "stop.circle.fill" : "waveform")
                }.disabled(controller.paused)
            }
            HStack {
                Text(controller.voiceState).font(.caption).foregroundStyle(controller.sendingVoice ? accent : .secondary)
                Spacer()
                Text("建议佩戴耳机 · 会议软件的静音与本助手独立").font(.caption).foregroundStyle(.secondary)
            }
            Text(controller.voiceRouteState).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 10).background(accent.opacity(0.06))
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            Image(systemName: "waveform.badge.mic").font(.system(size: 48, weight: .light)).foregroundStyle(accent)
            Text("开始一场会议").font(.system(size: 32, weight: .semibold))
            Text("在 Meet、Zoom 或 Teams 中正常开会。\n这里记录你的发言和电脑声音，实时显示字幕与翻译。")
                .font(.title3).foregroundStyle(.secondary).lineSpacing(6)
            HStack(alignment: .top, spacing: 30) {
                feature("01", "设置自己的 Key", "填写并保存，随时可更换")
                feature("02", "实时记录", "原文与译文并排保留")
                feature("03", "会议总结", "从实时原文提炼总结和待办")
            }.padding(.vertical, 12)
            HStack {
                if !controller.hasKey { SettingsLink { Label("打开设置", systemImage: "gearshape") }.buttonStyle(.borderedProminent) }
                else { Button("开始新会议") { Task { await controller.startMeeting() } }.buttonStyle(.borderedProminent) }
                Text("点击开始后，音频将发送至 OpenAI，使用你的 API 额度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("录音与会议记录保存在这台 Mac · 你可以随时暂停或结束").font(.caption).foregroundStyle(.secondary)
        }.padding(48).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func feature(_ number: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.caption.monospaced()).foregroundStyle(accent)
            Text(title).font(.headline); Text(text).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func meetingBody(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("内容", selection: $tab) { Text("对话全文").tag("transcript"); Text("会议总结").tag("summary") }
                    .pickerStyle(.segmented).frame(width: 230)
                Spacer()
                if !controller.busy {
                    Button(meeting.summary == nil ? "生成总结" : "更新总结") { Task { await controller.updateSummary() } }
                        .disabled(!meeting.displayedSegments.contains(where: \.hasText))
                }
                TextField("搜索发言", text: $search).textFieldStyle(.roundedBorder).frame(width: 190)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if tab == "summary" { summaryView(meeting) } else {
                if !controller.recording, !meeting.finalSegments.isEmpty {
                    HStack {
                        Picker("记录来源", selection: Binding(get: { transcriptSource ?? meeting.defaultTranscriptSource }, set: { transcriptSource = $0; evidenceID = nil })) {
                            Text("实时原文（\(meeting.liveSegments.count) 段）").tag(TranscriptSource.live)
                            Text("历史转写（\(meeting.finalSegments.count) 段）").tag(TranscriptSource.recording)
                        }.pickerStyle(.segmented).frame(width: 320)
                        Text("总结仅使用实时原文。历史转写独立保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 20).padding(.bottom, 8)
                }
                TranscriptTimeline(segments: meeting.segments(from: transcriptSource ?? meeting.defaultTranscriptSource), meeting: meeting,
                    title: controller.recording ? "实时字幕 · \(AppPreferences.languageName(meeting.subtitleLanguage))" : nil,
                    isLive: controller.recording, search: search, evidenceID: evidenceID,
                    notices: meeting.notices,
                    status: AudioSource.allCases.compactMap { source in controller.translationStates[source].map { "\(source.title)：\($0)" } }.joined(separator: " · ")).id(meeting.id)
            }
        }.onChange(of: meeting.id) { _, _ in transcriptSource = nil; evidenceID = nil; search = "" }
    }
    private func summaryView(_ meeting: Meeting) -> some View {
        ScrollView {
            if let summary = meeting.summary {
                VStack(alignment: .leading, spacing: 24) {
                    if meeting.summaryUsesDifferentTranscript {
                        Label(meeting.liveSegments.contains(where: \.hasText) ? "这份历史总结引用了旧版转写。更新总结将仅使用实时原文。" : "这份历史总结引用了旧版转写。本场没有可用于重新总结的实时原文。", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    summarySection("会议概要", icon: "text.alignleft", points: summary.overview)
                    summarySection("已作出的决策", icon: "checkmark.circle", points: summary.decisions)
                    summarySection("待办事项", icon: "checklist", points: summary.actions)
                    summarySection("待确认的问题", icon: "questionmark.circle", points: summary.questions)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView(meeting.liveSegments.contains(where: \.hasText) ? "尚未生成会议总结" : "没有可总结的实时原文", systemImage: "text.badge.checkmark", description: Text(meeting.liveSegments.contains(where: \.hasText) ? "点击生成总结，直接使用已有实时原文。每条总结附有原文引用。" : "本场录音仍保存在本机。"))
                    .padding(.top, 100)
            }
        }
    }
    private func summarySection(_ title: String, icon: String, points: [SummaryPoint]) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.title3.weight(.semibold)).foregroundStyle(accent)
            if points.isEmpty { Text("未记录明确内容").foregroundStyle(.secondary).font(.callout) }
            ForEach(points) { point in
                VStack(alignment: .leading, spacing: 8) {
                    Text(point.text).textSelection(.enabled).lineSpacing(4)
                    HStack { ForEach(point.evidence, id: \.self) { id in
                        Button("查看原文") { search = ""; tab = "transcript"; evidenceID = nil
                            transcriptSource = controller.current?.transcriptSource(forEvidence: id)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { evidenceID = id }
                        }.buttonStyle(.link).font(.caption)
                    } }
                }
            }
        }
    }
    private func stateName(_ state: String) -> String {
        ["recording": "录制中", "paused": "已暂停", "processing": "总结中", "recorded": "待总结", "interrupted": "待总结"][state] ?? state
    }
}

private struct AudioLevelView: View {
    @ObservedObject var levels: AudioLevels
    let source: AudioSource
    let detail: String
    private var level: Double { source == .microphone ? levels.microphone : levels.system }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: source == .microphone ? "mic" : "speaker.wave.2")
                Text(source == .microphone ? "麦克风" : "系统声音").fontWeight(.medium)
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 65 * min(1, max(0, level))) }
                    .frame(width: 65, height: 5)
                    .accessibilityLabel("音量").accessibilityValue("\(Int(min(1, max(0, level)) * 100))%")
            }.font(.caption)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(detail)
        }.frame(maxWidth: 230, alignment: .leading)
    }
}

struct TranscriptCard: View {
    let segment: TranscriptSegment
    let speaker: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(speaker)
                Text(timestamp(segment.start)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }.font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if segment.source == .microphone {
                    Text(segment.text).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2).textSelection(.enabled)
                } else {
                    Text(segment.translation ?? segment.text)
                        .font(.system(size: segment.translation != nil ? 19 : 14, weight: .medium))
                        .foregroundStyle(.primary).lineSpacing(3).textSelection(.enabled)
                    if distinctTranslation != nil {
                        Text(segment.text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(1).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
        .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottom) { Divider().opacity(0.2) }
    }
    private var distinctTranslation: String? {
        guard let translation = segment.translation,
              translation.trimmingCharacters(in: .whitespacesAndNewlines) != segment.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return translation
    }
}
