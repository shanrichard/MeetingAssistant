import SwiftUI
import MeetingCore

struct SettingsView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var audioSetup: BlackHoleSetup
    @State private var key = ""
    @State private var verifying = false
    @State private var deleteKey = false
    @State private var showingAudioSetup = false
    init(controller: MeetingController) {
        self.controller = controller
        audioSetup = controller.audioSetup
    }
    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField(controller.hasKey ? "粘贴 Key 以替换当前设置" : "sk-…", text: $key)
                        .textContentType(.password)
                }
                Button("保存") { if controller.saveKey(key) { key = "" } }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.isEmpty || controller.busy || verifying)
                HStack {
                    Button(verifying ? "验证中…" : "验证连接") {
                        verifying = true; Task { await controller.verifyKey(); verifying = false }
                    }.disabled(!controller.hasKey || verifying || controller.busy)
                    if controller.hasSavedKey { Button("删除保存的 Key", role: .destructive) { deleteKey = true }.disabled(controller.busy || verifying) }
                    Spacer()
                }
                if !controller.keyStatus.isEmpty { Text(controller.keyStatus).font(.caption).textSelection(.enabled) }
                Text("Key 安全保存在这台 Mac，下次启动可继续使用。使用你自己的 API 额度，Key 不进入会议记录或导出文件。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("OpenAI API Key") }
            Section("语言") {
                Picker("字幕与总结语言", selection: $controller.preferences.subtitleLanguage) {
                    ForEach(AppPreferences.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("向对方说的语言", selection: $controller.preferences.outgoingLanguage) {
                    ForEach(AppPreferences.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
            }.disabled(controller.busy)
            Section("音频设备") {
                Picker("真实麦克风", selection: $controller.preferences.microphoneUID) {
                    Text("请选择").tag("")
                    ForEach(controller.microphones) { Text($0.name).tag($0.uid) }
                }
                Picker("译音输出设备", selection: $controller.preferences.outputUID) {
                    Text("未选择虚拟设备").tag("")
                    ForEach(controller.virtualOutputs) { Text($0.name).tag($0.uid) }
                }
                HStack {
                    Button("刷新设备") { controller.refreshDevices() }
                    if !audioSetup.ready {
                        Button("设置同传音频…") { showingAudioSetup = true }
                    }
                }
                Text(audioSetup.status).font(.caption).foregroundStyle(.secondary)
                Link("同传音频使用 BlackHole · © Existential Audio Inc.", destination: BlackHolePackage.website)
                    .font(.caption)
                Text("开启同传时自动将系统麦克风切到译音设备，停止、暂停或结束后恢复。会议软件使用系统默认麦克风即可跟随切换；固定选择某个设备的软件不会跟随。助手继续采集上方真实麦克风，扬声器保持耳机。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("对方听到的是 AI 合成语音，请告知参会者。已是目标语言的发言可能不输出译音。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(controller.busy)
            Section("本地记录") {
                HStack { Text("录音与全文保存在本机"); Spacer(); Button("在 Finder 中打开") { NSWorkspace.shared.open(controller.storageURL) } }
                Text("录音保存在本机。会中音频发送至 OpenAI 生成实时字幕；结束后仅发送实时原文生成总结。建议先用耳机进行首次会议。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(controller.modelNames).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.formStyle(.grouped)
            .sheet(isPresented: $showingAudioSetup) { BlackHoleSetupView(setup: audioSetup) }
            .onAppear { audioSetup.refresh() }
            .onDisappear { key = ""; controller.savePreferences() }
            .onChange(of: controller.preferences.subtitleLanguage) { _, _ in controller.savePreferences() }
            .onChange(of: controller.preferences.outgoingLanguage) { _, _ in controller.savePreferences() }
            .onChange(of: controller.preferences.microphoneUID) { _, _ in controller.savePreferences() }
            .onChange(of: controller.preferences.outputUID) { _, _ in controller.savePreferences(); audioSetup.refresh() }
            .alert("删除这台 Mac 中保存的 API Key？", isPresented: $deleteKey) {
                Button("删除", role: .destructive) { controller.removeKey() }; Button("取消", role: .cancel) {}
            }
    }
}
