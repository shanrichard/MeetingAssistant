import SwiftUI
import AppKit

@main struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = MeetingController()
    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { delegate.controller = controller; controller.audioSetup.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    controller.audioSetup.refresh()
                }
        }
        .defaultSize(width: 1220, height: 810)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("开始新会议") { Task { await controller.startMeeting() } }.keyboardShortcut("n").disabled(controller.busy)
            }
        }
        Settings { SettingsView(controller: controller).frame(width: 610, height: 600) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: MeetingController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard controller.busy else { controller.stopVoice(); return .terminateNow }
        let alert = NSAlert(); alert.messageText = "会议工作仍在进行"
        alert.informativeText = "退出会停止采集和译音发送。实时原文与录音保留在本地，可稍后生成总结。"
        alert.addButton(withTitle: "继续工作"); alert.addButton(withTitle: "保存并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task { await controller.finishMeeting(process: false); controller.stopVoice(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stopVoice() }
}
