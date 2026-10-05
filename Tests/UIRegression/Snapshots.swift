import SwiftUI
import AppKit
import MeetingCore

/// `--snapshot <folder>` renders each synthetic screen to PNG in light and dark appearance, then exits.
/// Windows draw themselves, so no screen-recording permission is needed.
@MainActor enum SnapshotRunner {
    static var folder: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    }

    static func run(_ state: RegressionState, to folder: URL) async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await settle()
            guard let main = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else {
                throw MeetingError.message("No regression window")
            }
            main.setContentSize(NSSize(width: 1240, height: 800))
            // Key-window rendering: accent-coloured prominent buttons and selection.
            NSApp.activate(); main.makeKeyAndOrderFront(nil)
            let overlay = state.controller.captionOverlay
            let composite = window(OverlayComposite(overlay: overlay, controller: state.controller), size: NSSize(width: 1100, height: 620))
            let settings = window(SettingsView(controller: state.controller).frame(width: 640, height: 620), size: NSSize(width: 640, height: 620))
            for (name, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
                NSApp.appearance = appearance
                state.welcome(); try await save(main, folder, "\(name)-welcome")
                state.library(); try await save(main, folder, "\(name)-summary")
                state.captions(complete: true); try await save(main, folder, "\(name)-transcript")
                state.captions(); try await save(main, folder, "\(name)-live")
                state.library()
                for tab in ["general", "audio", "voice", "captions", "privacy"] {
                    UserDefaults.standard.set(tab, forKey: SettingsView.tabKey)
                    try await save(settings, folder, "\(name)-settings-\(tab)")
                }
                main.setContentSize(NSSize(width: 980, height: 640))
                state.captions(complete: true); try await save(main, folder, "\(name)-narrow-transcript")
                state.captions(); try await save(main, folder, "\(name)-narrow-live")
                main.setContentSize(NSSize(width: 1240, height: 800))
            }
            NSApp.appearance = nil
            state.captions()
            overlay.hovering = false; overlay.clickThrough = false
            try await save(composite, folder, "overlay-rest")
            overlay.hovering = true
            try await save(composite, folder, "overlay-hover")
            overlay.clickThrough = true; overlay.hoveringBadge = true
            try await save(composite, folder, "overlay-clickthrough")
            overlay.clickThrough = false; overlay.hovering = false; overlay.hoveringBadge = false
            let narrow = window(CaptionOverlayView(overlay: overlay, controller: state.controller), size: NSSize(width: 420, height: 120))
            overlay.hovering = true
            try await save(narrow, folder, "overlay-narrow-controls")
            narrow.orderOut(nil)
            // The real panel: transparent outside the captions, so the PNG keeps its alpha.
            overlay.show()
            guard let panel = NSApp.windows.first(where: { $0 is CaptionPanel }), panel.isVisible else {
                throw MeetingError.message("Caption panel did not appear")
            }
            try await save(panel, folder, "overlay-panel")
            panel.setContentSize(NSSize(width: 420, height: 120))
            try await save(panel, folder, "overlay-narrow")
            guard panel.level == .floating, !panel.isOpaque, panel.collectionBehavior.contains(.fullScreenAuxiliary) else {
                throw MeetingError.message("Caption panel is not a transparent floating panel")
            }
            state.controller.recording = false
            await settle()
            guard !panel.isVisible, !overlay.visible else { throw MeetingError.message("Caption panel stayed after recording ended") }
            print("Snapshots written to \(folder.path)")
            exit(0)
        } catch {
            print("FAIL: \(error.localizedDescription)"); exit(1)
        }
    }

    private static func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }

    private static func window(_ view: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.orderFront(nil)
        return window
    }

    private static func save(_ window: NSWindow, _ folder: URL, _ name: String) async throws {
        await settle()
        // The frame view includes the title bar and toolbar of the main window.
        let view = window.toolbar == nil ? window.contentView! : (window.contentView?.superview ?? window.contentView!)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MeetingError.message("No bitmap for \(name)") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw MeetingError.message("No PNG for \(name)") }
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }
}

/// The captions panel over a stand-in video call, as a participant would see the screen.
private struct OverlayComposite: View {
    @ObservedObject var overlay: CaptionOverlay
    let controller: MeetingController
    var body: some View {
        ZStack(alignment: .bottom) {
            MeetingBackdrop()
            CaptionOverlayView(overlay: overlay, controller: controller)
                .frame(width: 820, height: 230)
                .padding(.bottom, 36)
        }
    }
}
