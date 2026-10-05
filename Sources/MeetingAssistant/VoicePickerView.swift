import SwiftUI
import MeetingCore

struct VoicePickerView: View {
    @ObservedObject var controller: MeetingController
    @StateObject private var preview = VoicePreviewPlayer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("试听并选择声音").font(.title2.bold())
                    Text("每种声音朗读相同的中英短句，方便比较。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { preview.stop(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("离线试听 · 无需 API Key · 建议戴耳机")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(InterpreterVoice.allCases) { voice in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(voice.name).font(.headline)
                                Text(voice == .marin ? "默认音色" : voice.label.components(separatedBy: " · ").dropFirst().joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                preview.toggle(voice)
                            } label: {
                                Label(preview.playingVoice == voice ? "停止" : "试听",
                                      systemImage: preview.playingVoice == voice ? "stop.fill" : "play.fill")
                                    .frame(width: 60)
                            }
                            .accessibilityLabel("\(preview.playingVoice == voice ? "停止试听" : "试听") \(voice.name)")
                            .disabled(controller.busy || controller.sendingVoice)
                            Button {
                                controller.preferences.outgoingVoice = voice
                                controller.savePreferences()
                            } label: {
                                Text(controller.preferences.outgoingVoice == voice ? "已选用" : "选用")
                                    .frame(width: 48)
                            }
                            .tint(controller.preferences.outgoingVoice == voice ? .accentColor : nil)
                            .accessibilityLabel("\(controller.preferences.outgoingVoice == voice ? "已选用" : "选用") \(voice.name)")
                            .disabled(controller.sendingVoice || controller.preferences.outgoingVoice == voice)
                        }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(controller.preferences.outgoingVoice == voice ? Color.accentColor.opacity(0.07) : Color.clear)
                        Divider()
                    }
                }
            }
            .background(.background).clipShape(RoundedRectangle(cornerRadius: 10))
            if !preview.error.isEmpty {
                Text(preview.error).font(.caption).foregroundStyle(.red)
            } else if let voice = preview.playingVoice {
                Label("正在试听 \(voice.name) · \(preview.outputName)", systemImage: "speaker.wave.2.fill")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(controller.busy ? "记录期间暂停试听，避免试听声音进入录音。" : "点击“选用”自动保存；试听不会改变当前选择。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 580, height: 640)
        .onDisappear { preview.stop() }
        .onChange(of: controller.busy) { _, busy in if busy { preview.stop() } }
        .onChange(of: controller.sendingVoice) { _, sending in if sending { preview.stop() } }
    }
}
