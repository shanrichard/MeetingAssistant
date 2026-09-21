import SwiftUI

struct BlackHoleSetupView: View {
    @ObservedObject var setup: BlackHoleSetup
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("准备同传音频", systemImage: "waveform.badge.mic")
                .font(.title2.weight(.semibold))
            Text("MeetingAssistant 使用 BlackHole 2ch 虚拟音频设备，把你的译音送入会议软件。")
            HStack(alignment: .top, spacing: 10) {
                if setup.working { ProgressView().controlSize(.small) }
                else { Image(systemName: setup.ready ? "checkmark.circle.fill" : "info.circle").foregroundStyle(setup.ready ? .green : .secondary) }
                Text(setup.status).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            if !setup.ready {
                Text("安装包直接从 BlackHole 官方网站下载。macOS 安装器会请求管理员授权，并可能要求重启。请先结束其他应用中的通话。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("暂时跳过也可以使用录音和字幕，稍后可在设置中继续安装。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Link("BlackHole 官网", destination: BlackHolePackage.website)
                Spacer()
                Text("© Existential Audio Inc. 保留所有权利。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if setup.working {
                    Button(setup.phase == .downloading ? "取消下载" : "取消") { setup.cancelDownload() }
                } else {
                    Button(setup.ready ? "完成" : "稍后") { setup.presented = false; dismiss() }
                    Spacer()
                    if !setup.ready { Button("重新检测") { setup.refresh() } }
                    if setup.canInstall {
                        Button(setup.phase == .waitingForInstaller ? "重新打开安装流程" : "下载并安装 BlackHole 2ch") { setup.install() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }.padding(26).frame(width: 550)
            .interactiveDismissDisabled(setup.working)
            .task {
                while !Task.isCancelled {
                    setup.refresh()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
    }
}
