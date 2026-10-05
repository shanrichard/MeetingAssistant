import SwiftUI
import AppKit

@main struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = MeetingController()
    var body: some Scene {
        // One library window; the floating captions reopen it by this id.
        Window("Meeting Assistant", id: "main") {
            ContentView(controller: controller)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.controller = controller; controller.audioSetup.start(); controller.calendar.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    controller.audioSetup.refresh()
                }
        }
        .defaultSize(width: 1220, height: 810)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("开始新会议") { Task { await controller.requestStart() } }.keyboardShortcut("n").disabled(controller.busy)
                Button("开始临时会议") { Task { await controller.startMeeting() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(controller.busy)
            }
            CommandMenu("会议") {
                Button("显示或隐藏悬浮字幕") { controller.captionOverlay.toggle() }
                    .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!controller.recording)
                Button("切换鼠标穿透") {
                    if controller.captionOverlay.visible { controller.captionOverlay.clickThrough.toggle() }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!controller.recording)
                Divider()
                Button(controller.paused ? "继续记录" : "暂停记录") { controller.togglePause() }.disabled(!controller.recording)
                Button("结束会议") { Task { await controller.finishMeeting() } }.disabled(!controller.recording)
            }
        }
        Settings { SettingsView(controller: controller).frame(width: 640, height: 620) }
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
