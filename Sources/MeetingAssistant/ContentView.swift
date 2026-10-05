import SwiftUI
import MeetingCore

struct ContentView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var audioSetup: BlackHoleSetup
    @Environment(\.openWindow) private var openWindow
    @State private var librarySearch = ""
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var pendingDeletion: Meeting?
    init(controller: MeetingController) {
        self.controller = controller
        audioSetup = controller.audioSetup
    }
    var body: some View {
        NavigationSplitView {
            MeetingSidebar(controller: controller, search: $librarySearch, rename: rename, delete: { pendingDeletion = $0 })
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            if let meeting = controller.current {
                MeetingDetailView(controller: controller, meeting: meeting,
                                  rename: { rename(meeting) }, delete: { pendingDeletion = meeting })
            } else {
                WelcomeView(controller: controller)
            }
        }
        .navigationTitle(controller.current?.title ?? "Meeting Assistant")
        .modifier(HiddenToolbarTitle())
        .tint(accent)
        .sheet(isPresented: $audioSetup.presented) { BlackHoleSetupView(setup: audioSetup) }
        .sheet(isPresented: $controller.needsKeySetup) { APIKeySetupSheet(controller: controller) }
        .alert("需要注意", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("知道了") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
        .alert("重命名会议", isPresented: $renaming) {
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
        .onAppear { controller.captionOverlay.showMainWindow = { openWindow(id: "main") } }
    }
    private func rename(_ meeting: Meeting) {
        // Renaming acts on the selection, so a context-menu rename selects its row first.
        controller.selectedID = meeting.id
        titleDraft = meeting.title; renaming = true
    }
}

/// The meeting title already leads the detail pane; keep it out of the toolbar where supported.
private struct HiddenToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct LibraryGroup: Identifiable {
    let title: String
    var meetings: [Meeting]
    var id: String { title }
    var showsDate: Bool { title != "今天" && title != "昨天" }
}

private struct MeetingSidebar: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var audioSetup: BlackHoleSetup
    @Binding var search: String
    let rename: (Meeting) -> Void
    let delete: (Meeting) -> Void
    init(controller: MeetingController, search: Binding<String>, rename: @escaping (Meeting) -> Void, delete: @escaping (Meeting) -> Void) {
        self.controller = controller; audioSetup = controller.audioSetup
        _search = search; self.rename = rename; self.delete = delete
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                primaryAction
                SearchField(text: $search, prompt: "搜索会议或发言")
            }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
            List(selection: $controller.selectedID) {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, showsDate: group.showsDate).tag(meeting.id)
                                .contextMenu { menu(for: meeting) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(controller.busy)
            .overlay { if groups.isEmpty { emptyState } }
            Divider()
            footer
        }
    }

    private var groups: [LibraryGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? controller.meetings : controller.meetings.filter { Self.matches($0, query) }
        var result: [LibraryGroup] = []
        for meeting in matches {
            let title = librarySection(for: meeting.createdAt)
            if result.last?.title == title { result[result.count - 1].meetings.append(meeting) }
            else { result.append(LibraryGroup(title: title, meetings: [meeting])) }
        }
        return result
    }
    private static func matches(_ meeting: Meeting, _ query: String) -> Bool {
        meeting.title.localizedCaseInsensitiveContains(query) || meeting.liveSegments.contains {
            $0.text.localizedCaseInsensitiveContains(query) || ($0.translation ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if controller.recording {
            HStack(spacing: 10) {
                RecordingDot(paused: controller.paused, elapsed: controller.elapsed, size: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.paused ? "会议已暂停" : "会议进行中").font(.system(size: 12, weight: .semibold))
                    Text(timestamp(controller.elapsed)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Button { Task { await controller.startMeeting() } } label: {
                HStack(spacing: 8) {
                    if controller.starting { ProgressView().controlSize(.small) } else { Image(systemName: "record.circle") }
                    Text(controller.starting ? "正在准备…" : "开始会议").fontWeight(.semibold)
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).opacity(0.7)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(controller.busy || audioSetup.working)
        }
    }

    @ViewBuilder private func menu(for meeting: Meeting) -> some View {
        Button("重命名…") { rename(meeting) }
        Button("导出 Markdown…") { controller.selectedID = meeting.id; controller.export() }
        Button("在 Finder 中显示") { controller.revealInFinder(meeting.id) }
        Divider()
        Button("删除会议…", role: .destructive) { delete(meeting) }.disabled(controller.busy)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: controller.meetings.isEmpty ? "tray" : "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
            Text(controller.meetings.isEmpty ? "还没有会议记录" : "没有匹配的会议").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            SettingsLink { Label("设置", systemImage: "gearshape") }.buttonStyle(.borderless)
            Spacer()
            if controller.hasKey {
                Label { Text("Key 已保存") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    .foregroundStyle(.secondary)
            } else {
                SettingsDestinationLink(tab: "general") { Label("未设置 API Key", systemImage: "exclamationmark.triangle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let showsDate: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
            HStack(spacing: 5) {
                Text(showsDate ? meeting.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                               : meeting.createdAt.formatted(date: .omitted, time: .shortened))
                let duration = durationText(meeting.duration)
                if !duration.isEmpty { Text("·"); Text(duration) }
                Spacer(minLength: 4)
                StateBadge(state: meeting.state)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct WelcomeView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var audioSetup: BlackHoleSetup
    init(controller: MeetingController) {
        self.controller = controller
        audioSetup = controller.audioSetup
    }
    private var microphone: AudioDevice? { controller.microphones.first { $0.uid == controller.preferences.microphoneUID } }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    Text("开始一场会议").font(.system(size: 28, weight: .semibold))
                    Text("在 Zoom、Meet 或 Teams 中照常开会。\n这里实时显示字幕与翻译，结束后生成带原文引用的总结。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(4)
                }
                VStack(spacing: 0) {
                    SetupRow(done: controller.hasKey, icon: "key.fill", title: "OpenAI API Key",
                             detail: controller.hasKey ? "已保存在这台 Mac 的钥匙串" : "使用你自己的 API 额度") {
                        if !controller.hasKey { SettingsDestinationLink(tab: "general") { Text("设置") } }
                    }
                    Divider().padding(.leading, 54)
                    SetupRow(done: microphone != nil, icon: "mic.fill", title: "麦克风",
                             detail: microphone?.name ?? "请在设置中选择真实麦克风") {
                        if microphone == nil { SettingsDestinationLink(tab: "audio") { Text("选择") } }
                    }
                    Divider().padding(.leading, 54)
                    SetupRow(done: true, icon: "globe", title: "语言",
                             detail: "字幕 \(AppPreferences.languageName(controller.preferences.subtitleLanguage)) · 对外 \(AppPreferences.languageName(controller.preferences.outgoingLanguage))") {
                        SettingsDestinationLink(tab: "general") { Text("更改") }
                    }
                    Divider().padding(.leading, 54)
                    SetupRow(done: audioSetup.ready, optional: true, icon: "waveform", title: "向会议发送译音（可选）",
                             detail: audioSetup.ready ? audioSetup.status : "需要 BlackHole 2ch 虚拟音频设备") {
                        if !audioSetup.ready { Button("设置…") { audioSetup.presented = true }.disabled(audioSetup.working) }
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                VStack(spacing: 10) {
                    Button { Task { await controller.startMeeting() } } label: {
                        Label("开始会议", systemImage: "record.circle").frame(minWidth: 180).padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(controller.busy || audioSetup.working)
                    Text("开始后音频会发送至 OpenAI 生成实时字幕，使用你的 API 额度 · 录音与记录保存在这台 Mac")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 540).padding(40).frame(maxWidth: .infinity)
        }
    }
}

private struct SetupRow<Accessory: View>: View {
    let done: Bool
    var optional = false
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(done ? accent : Color.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            accessory()
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "exclamationmark.circle.fill"))
                .foregroundStyle(done ? Color.green : (optional ? Color.secondary : Color.orange))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}
