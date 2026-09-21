import SwiftUI

/// Exercise production onboarding without downloading or opening the real Installer.
@MainActor private final class BlackHolePreviewState: ObservableObject {
    var devices: [AudioDevice] = []
    var installed = false
    lazy var setup = BlackHoleSetup(listDevices: { [unowned self] in devices },
        installedOnDisk: { [unowned self] in installed },
        download: { throw URLError(.notConnectedToInternet) },
        verify: { _ in }, openInstaller: { _ in })
    init() {
        setup.configureDevices = { AudioDevices.preferredTranslationOutput(in: $0, currentUID: "") }
    }
    func show(_ mode: String) {
        devices = mode == "installed" ? [AudioDevice(id: 1, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", input: true, output: true, virtual: true)] : []
        installed = mode == "restart"
        setup.refresh()
    }
}

struct BlackHolePreview: View {
    @StateObject private var state = BlackHolePreviewState()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("离线安装引导预览").font(.caption)
                Button("已有设备") { state.show("installed") }
                Button("尚未安装") { state.show("missing") }
                Button("等待重启") { state.show("restart") }
            }.padding()
            Divider()
            BlackHoleSetupView(setup: state.setup)
        }
    }
}
