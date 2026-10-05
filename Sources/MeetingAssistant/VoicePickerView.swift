import SwiftUI
import MeetingCore

/// Settings tab: preview every interpreter voice offline and pick the one sent to the meeting.
struct VoicePickerView: View {
    @ObservedObject var controller: MeetingController
    @StateObject private var preview = VoicePreviewPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("向会议说话的声音").font(.headline)
                Text("每种声音朗读相同的中英短句，方便比较。离线试听 · 无需 API Key · 建议戴耳机")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(InterpreterVoice.allCases) { voice in row(voice) }
                }
            }
            status.font(.caption)
        }
        .padding(20)
        .onDisappear { preview.stop() }
        .onChange(of: controller.busy) { _, busy in if busy { preview.stop() } }
        .onChange(of: controller.sendingVoice) { _, sending in if sending { preview.stop() } }
    }

    private func row(_ voice: InterpreterVoice) -> some View {
        let selected = controller.preferences.outgoingVoice == voice
        let playing = preview.playingVoice == voice
        let previewDisabled = controller.busy || controller.sendingVoice
        return HStack(spacing: 12) {
            Button { preview.toggle(voice) } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(playing ? Color.orange : accent, in: Circle())
            }
            .buttonStyle(.plain).opacity(previewDisabled ? 0.4 : 1)
            .accessibilityLabel("\(playing ? "停止试听" : "试听") \(voice.name)")
            .disabled(previewDisabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name).font(.system(size: 13, weight: .semibold))
                Text(voice == .marin ? "默认音色" : voice.label.components(separatedBy: " · ").dropFirst().joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Label("已选用", systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(accent)
                    .accessibilityLabel("已选用 \(voice.name)")
            } else {
                Button("选用") {
                    controller.preferences.outgoingVoice = voice
                    controller.savePreferences()
                }
                .accessibilityLabel("选用 \(voice.name)")
                .disabled(controller.sendingVoice)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? accent.opacity(0.1) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? accent.opacity(0.45) : Color.clear))
    }

    @ViewBuilder private var status: some View {
        if !preview.error.isEmpty {
            Text(preview.error).foregroundStyle(.red)
        } else if let voice = preview.playingVoice {
            Label("正在试听 \(voice.name) · \(preview.outputName)", systemImage: "speaker.wave.2.fill").foregroundStyle(.secondary)
        } else if controller.sendingVoice {
            Text("正在使用 \(controller.preferences.outgoingVoice.name)。如需换声音，请先停止发送译音。").foregroundStyle(.secondary)
        } else {
            Text(controller.busy ? "记录期间暂停试听，避免试听声音进入录音。" : "点击“选用”自动保存，每次发送译音都使用同一声音；试听不会改变当前选择。")
                .foregroundStyle(.secondary)
        }
    }
}
