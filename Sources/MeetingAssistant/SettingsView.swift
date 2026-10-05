import SwiftUI
import MeetingCore

/// Task-specific setup links should not reopen an unrelated, previously selected tab.
struct SettingsDestinationLink<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    let tab: String
    @ViewBuilder let label: () -> Label
    var body: some View {
        Button {
            UserDefaults.standard.set(tab, forKey: SettingsView.tabKey)
            openSettings()
        } label: { label() }
    }
}

struct SettingsView: View {
    static let tabKey = "settingsTab"
    @ObservedObject var controller: MeetingController
    @AppStorage(SettingsView.tabKey) private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(controller: controller).tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            AudioSettings(controller: controller).tabItem { Label("音频", systemImage: "hifispeaker.2") }.tag("audio")
            VoicePickerView(controller: controller).tabItem { Label("同传声音", systemImage: "person.wave.2") }.tag("voice")
            GoogleAccountSettings(controller: controller).tabItem { Label("Google 账号", systemImage: "person.crop.circle") }.tag("google")
            CaptionSettings().tabItem { Label("悬浮字幕", systemImage: "captions.bubble") }.tag("captions")
            PrivacySettings(controller: controller).tabItem { Label("隐私", systemImage: "lock.shield") }.tag("privacy")
        }
        .onDisappear { controller.savePreferences() }
        .onChange(of: controller.preferences.subtitleLanguage) { _, _ in controller.savePreferences() }
        .onChange(of: controller.preferences.outgoingLanguage) { _, _ in controller.savePreferences() }
        .onChange(of: controller.preferences.outgoingVoice) { _, _ in controller.savePreferences() }
        .onChange(of: controller.preferences.microphoneUID) { _, _ in controller.savePreferences() }
        .onChange(of: controller.preferences.outputUID) { _, _ in controller.savePreferences(); controller.audioSetup.refresh() }
    }
}

/// Shown when an action needs a key and none is saved.
struct APIKeySetupSheet: View {
    @ObservedObject var controller: MeetingController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置 OpenAI API Key").font(.title3.weight(.semibold))
                Text("开始会议和生成总结需要你自己的 Key。").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 22)
            Form { APIKeySection(controller: controller) }.formStyle(.grouped).scrollDisabled(true)
            HStack { Spacer(); Button("完成") { controller.needsKeySetup = false } }
                .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 540, height: 360)
    }
}

struct APIKeySection: View {
    @ObservedObject var controller: MeetingController
    @State private var key = ""
    @State private var verifying = false
    @State private var deleteKey = false
    var body: some View {
        Section {
            HStack {
                SecureField("API Key", text: $key, prompt: Text(controller.hasKey ? "粘贴新的 Key 以替换当前设置" : "sk-…"))
                    .textContentType(.password).onSubmit(save)
                Button("保存", action: save).buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty || controller.busy || verifying)
            }
            HStack {
                Label { Text(controller.hasSavedKey ? "已保存在这台 Mac 的钥匙串" : "尚未保存 Key") } icon: {
                    Image(systemName: controller.hasSavedKey ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(controller.hasSavedKey ? Color.green : Color.orange)
                }
                Spacer()
                Button(verifying ? "验证中…" : "验证连接") {
                    verifying = true; Task { await controller.verifyKey(); verifying = false }
                }.disabled(!controller.hasKey || verifying || controller.busy)
                if controller.hasSavedKey {
                    Button("删除…", role: .destructive) { deleteKey = true }.disabled(controller.busy || verifying)
                }
            }
            if !controller.keyStatus.isEmpty { Text(controller.keyStatus).font(.caption).textSelection(.enabled) }
        } header: { Text("OpenAI API Key") } footer: {
            Text("Key 安全保存在这台 Mac，下次启动可继续使用。使用你自己的 API 额度，Key 不进入会议记录或导出文件。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { key = "" }
        .alert("删除这台 Mac 中保存的 API Key？", isPresented: $deleteKey) {
            Button("删除", role: .destructive) { controller.removeKey() }; Button("取消", role: .cancel) {}
        }
    }
    private func save() {
        guard !key.isEmpty, !controller.busy, !verifying else { return }
        if controller.saveKey(key) { key = "" }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var controller: MeetingController
    var body: some View {
        Form {
            APIKeySection(controller: controller)
            Section("语言") {
                Picker("字幕与总结语言", selection: $controller.preferences.subtitleLanguage) {
                    ForEach(AppPreferences.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("我说话时翻译成", selection: $controller.preferences.outgoingLanguage) {
                    ForEach(AppPreferences.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            .disabled(controller.busy)
        }
        .formStyle(.grouped)
    }
}

private struct AudioSettings: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var audioSetup: BlackHoleSetup
    @State private var showingAudioSetup = false
    init(controller: MeetingController) {
        self.controller = controller
        audioSetup = controller.audioSetup
    }
    var body: some View {
        Form {
            Section {
                Picker("真实麦克风", selection: $controller.preferences.microphoneUID) {
                    Text("请选择").tag("")
                    ForEach(controller.microphones) { Text($0.name).tag($0.uid) }
                }
            } header: { Text("采集") } footer: {
                Text("助手分别采集这个物理麦克风和电脑的系统声音。建议佩戴耳机，避免扬声器声音再次进入麦克风。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: audioSetup.ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(audioSetup.ready ? Color.green : Color.orange)
                    Text(audioSetup.status).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !audioSetup.ready { Button("设置同传音频…") { showingAudioSetup = true } }
                }
                Picker("译音输出设备", selection: $controller.preferences.outputUID) {
                    Text("未选择虚拟设备").tag("")
                    ForEach(controller.virtualOutputs) { Text($0.name).tag($0.uid) }
                }
                HStack { Spacer(); Button("刷新设备") { controller.refreshDevices() } }
            } header: { Text("向会议发送译音") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("开启同传时自动将系统麦克风切到译音设备，停止、暂停或结束后恢复。会议软件使用“系统默认麦克风”即可跟随切换；固定选择某个设备的软件不会跟随。助手继续采集上方的真实麦克风。")
                    Text("对方听到的是 AI 合成语音，请告知参会者。已是目标语言的发言可能不输出译音。")
                    Link("同传音频使用 BlackHole · © Existential Audio Inc.", destination: BlackHolePackage.website)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(controller.busy)
        .sheet(isPresented: $showingAudioSetup) { BlackHoleSetupView(setup: audioSetup) }
        .onAppear { audioSetup.refresh() }
    }
}

private struct CaptionSettings: View {
    @AppStorage(CaptionOverlay.autoShowKey) private var autoShow = true
    @AppStorage(CaptionOverlay.opacityKey) private var opacity = CaptionOverlay.defaultOpacity
    @AppStorage(CaptionOverlay.fontSizeKey) private var fontSize = CaptionOverlay.defaultFontSize
    @AppStorage(CaptionOverlay.showOriginalKey) private var showOriginal = true
    @AppStorage(CaptionOverlay.showMineKey) private var showMine = true
    var body: some View {
        Form {
            Section {
                CaptionPreview(opacity: opacity, fontSize: fontSize, showOriginal: showOriginal, showMine: showMine)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Toggle("开始会议时自动显示", isOn: $autoShow)
                LabeledContent("背景不透明度") {
                    HStack {
                        Slider(value: $opacity, in: CaptionOverlay.opacityRange).labelsHidden()
                        Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("字号") {
                    HStack {
                        Slider(value: $fontSize, in: CaptionOverlay.fontRange, step: 2).labelsHidden()
                        Text("\(Int(fontSize))").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("显示原文", isOn: $showOriginal)
                Toggle("显示我的发言", isOn: $showMine)
            } footer: {
                Text("悬浮字幕显示在会议窗口上方，可拖动位置、拖右下角调整大小。点按锁形按钮开启鼠标穿透后，点击会直接落到下层的会议窗口；把鼠标移到右上角的锁形图标即可解除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The floating captions over a stand-in video call, so appearance can be tuned before a meeting.
struct CaptionPreview: View {
    let opacity: Double
    let fontSize: Double
    let showOriginal: Bool
    let showMine: Bool
    private static let samples = [
        TranscriptSegment(id: "preview-1", source: .system, start: 0, end: 3, text: "Can everyone see my screen?", translation: "大家能看到我的屏幕吗？"),
        TranscriptSegment(id: "preview-2", source: .microphone, start: 4, end: 6, text: "可以看到，请继续。"),
        TranscriptSegment(id: "preview-3", source: .system, start: 7, end: 11, text: "We should ship the beta next Friday.", translation: "我们应该在下周五发布测试版。"),
    ]
    var body: some View {
        ZStack(alignment: .bottom) {
            MeetingBackdrop()
            CaptionStack(segments: Self.samples.filter { showMine || $0.source == .system }, fontSize: fontSize,
                         showOriginal: showOriginal, placeholder: "")
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(height: 150)
                .background(Color.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(14)
                .environment(\.colorScheme, .dark)
        }
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A stand-in for a video call: participant tiles behind the captions.
struct MeetingBackdrop: View {
    private let tiles: [(Color, Color)] = [(Color(red: 0.32, green: 0.42, blue: 0.55), Color(red: 0.16, green: 0.2, blue: 0.3)),
                                           (Color(red: 0.55, green: 0.42, blue: 0.33), Color(red: 0.28, green: 0.2, blue: 0.16)),
                                           (Color(red: 0.33, green: 0.5, blue: 0.42), Color(red: 0.15, green: 0.26, blue: 0.22))]
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 6) {
                ForEach(tiles.indices, id: \.self) { index in
                    LinearGradient(colors: [tiles[index].0, tiles[index].1], startPoint: .top, endPoint: .bottom)
                        .overlay {
                            Image(systemName: "person.fill").resizable().scaledToFit()
                                .frame(height: proxy.size.height * 0.5).foregroundStyle(.white.opacity(0.55))
                                .offset(y: proxy.size.height * 0.08)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(6)
        }
        .background(Color(white: 0.08))
    }
}

private struct PrivacySettings: View {
    @ObservedObject var controller: MeetingController
    var body: some View {
        Form {
            Section("本地记录") {
                LabeledContent("录音与全文保存在本机") {
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(controller.storageURL) }
                }
                Text("会中音频发送至 OpenAI 生成实时字幕；结束后仅发送实时原文生成总结，不会上传录音。Markdown 导出不含录音和 Key。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("使用的模型") {
                Text(controller.modelNames).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
