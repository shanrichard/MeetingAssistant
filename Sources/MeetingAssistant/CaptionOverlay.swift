import SwiftUI
import AppKit
import Combine
import MeetingCore

/// See-through captions floating above the meeting app, so faces and shared screens stay visible behind them.
@MainActor final class CaptionOverlay: ObservableObject {
    static let autoShowKey = "captionOverlay.autoShow"
    static let opacityKey = "captionOverlay.backgroundOpacity"
    static let fontSizeKey = "captionOverlay.fontSize"
    static let showOriginalKey = "captionOverlay.showOriginal"
    static let showMineKey = "captionOverlay.showMine"
    static let defaultOpacity = 0.4
    static let defaultFontSize = 24.0
    /// Fully transparent pixels let clicks through, so the background never reaches zero.
    static let opacityRange: ClosedRange<Double> = 0.05...0.9
    static let fontRange: ClosedRange<Double> = 16...40
    private static let frameName = "CaptionOverlay"
    private static let badgeArea: CGFloat = 46

    @Published private(set) var visible = false
    /// Clicks fall through to the meeting window; only the lock badge in the corner stays clickable.
    @Published var clickThrough = false { didSet { trackMouse() } }
    @Published var hovering = false
    @Published var hoveringBadge = false
    var showMainWindow: () -> Void = {}
    private weak var controller: MeetingController?
    private var panel: CaptionPanel?
    private var mouseTimer: Timer?
    private var recordingObserver: AnyCancellable?
    private var dragStart: (mouse: NSPoint, frame: NSRect)?
    private var moving = false

    func attach(_ controller: MeetingController) {
        self.controller = controller
        recordingObserver = controller.$recording.removeDuplicates().sink { [weak self] recording in
            if !recording { self?.hide() }
        }
    }
    func meetingStarted() {
        if UserDefaults.standard.object(forKey: Self.autoShowKey) as? Bool ?? true { show() }
    }
    func toggle() { visible ? hide() : show() }
    func show() {
        guard let controller else { return }
        let panel = self.panel ?? makePanel(controller)
        self.panel = panel
        panel.orderFrontRegardless()
        visible = true
        startTracking()
    }
    func hide() {
        mouseTimer?.invalidate(); mouseTimer = nil
        panel?.orderOut(nil)
        visible = false; hovering = false; hoveringBadge = false
        if clickThrough { clickThrough = false }
    }
    func openMainWindow() {
        NSApp.activate()
        showMainWindow()
    }
    func endMeeting() {
        guard let controller else { return }
        // The summary appears in the main window, which is usually behind the meeting app.
        openMainWindow()
        Task { await controller.finishMeeting() }
    }

    // Let AppKit own the drag, including the first click while the meeting app is active.
    func drag(with event: NSEvent) {
        guard let panel, !clickThrough else { return }
        moving = true
        panel.performDrag(with: event)
        moving = false
        panel.saveFrame(usingName: Self.frameName)
        trackMouse()
    }
    // Resize from screen-space mouse positions, so the panel never chases its own coordinates.
    func resize() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, panel.frame)
        dragStart = start
        let width = max(panel.minSize.width, start.frame.width + mouse.x - start.mouse.x)
        let height = max(panel.minSize.height, start.frame.height - (mouse.y - start.mouse.y))
        panel.setFrame(NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height), display: true)
    }
    func endDrag() { dragStart = nil }

    private func makePanel(_ controller: MeetingController) -> CaptionPanel {
        let panel = CaptionPanel()
        let host = FirstMouseHostingView(rootView: CaptionOverlayView(overlay: self, controller: controller))
        host.sizingOptions = []
        panel.contentView = host
        let restored = panel.setFrameUsingName(Self.frameName)
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }
    private static func defaultFrame() -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(860, screen.width * 0.7), height: CGFloat = 230
        return NSRect(x: screen.midX - width / 2, y: screen.minY + 72, width: width, height: height)
    }

    // Polling works whether or not this app is active, unlike tracking areas in a non-activating panel.
    private func startTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
        trackMouse()
    }
    private func trackMouse() {
        guard let panel, visible else { return }
        let mouse = NSEvent.mouseLocation, frame = panel.frame
        let badge = NSRect(x: frame.maxX - Self.badgeArea, y: frame.maxY - Self.badgeArea, width: Self.badgeArea, height: Self.badgeArea)
        let inside = frame.contains(mouse) || moving || dragStart != nil
        let onBadge = clickThrough && badge.contains(mouse)
        if hovering != inside { withAnimation(.easeOut(duration: 0.18)) { hovering = inside } }
        if hoveringBadge != onBadge { hoveringBadge = onBadge }
        let ignores = clickThrough && !onBadge
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }
}

final class CaptionPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 230),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        title = "悬浮字幕"
        isFloatingPanel = true
        level = .floating
        // Stay visible over a full-screen Zoom/Meet window and on every Space.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        minSize = NSSize(width: 420, height: 120)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Controls respond to the first click even though the meeting app stays frontmost.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A native mouse surface avoids SwiftUI background gestures being swallowed by the hosted content.
private struct CaptionDragArea: NSViewRepresentable {
    var onDrag: (NSEvent) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.onDrag = onDrag }

    final class DragView: NSView {
        var onDrag: ((NSEvent) -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onDrag?(event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

struct CaptionOverlayView: View {
    @ObservedObject var overlay: CaptionOverlay
    @ObservedObject var controller: MeetingController
    @AppStorage(CaptionOverlay.opacityKey) private var backgroundOpacity = CaptionOverlay.defaultOpacity
    @AppStorage(CaptionOverlay.fontSizeKey) private var fontSize = CaptionOverlay.defaultFontSize
    @AppStorage(CaptionOverlay.showOriginalKey) private var showOriginal = true
    @AppStorage(CaptionOverlay.showMineKey) private var showMine = true

    var body: some View {
        ZStack(alignment: .top) {
            background
            CaptionStack(segments: segments, fontSize: fontSize, showOriginal: showOriginal, placeholder: placeholder)
                .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 16)
                .opacity(captionOpacity)
                .allowsHitTesting(false)
            if overlay.clickThrough {
                HStack { quietStatus; Spacer(); lockBadge }.padding(8)
            } else if overlay.hovering {
                CaptionToolbar(overlay: overlay, controller: controller, backgroundOpacity: $backgroundOpacity,
                               fontSize: $fontSize, showOriginal: $showOriginal, showMine: $showMine)
                    .transition(.opacity)
            } else {
                HStack { quietStatus; Spacer() }.padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if overlay.hovering && !overlay.clickThrough { resizeGrip }
        }
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 420, minHeight: 120)
    }

    private var meeting: Meeting? { controller.liveMeeting ?? controller.current }
    private var segments: [TranscriptSegment] {
        guard let meeting else { return [] }
        let live = meeting.segments(from: .live).filter { $0.hasCaptionText && (showMine || $0.source == .system) }
        return Array(live.suffix(12))
    }
    private var placeholder: String {
        if controller.paused { return "已暂停 · 继续记录后恢复字幕" }
        return controller.translationStates.isEmpty ? "正在连接实时字幕…" : "正在聆听…"
    }
    private var captionOpacity: Double {
        // While clicks pass through, fade the text under the cursor so the meeting window can be read.
        if overlay.clickThrough && overlay.hovering && !overlay.hoveringBadge { return 0.25 }
        return controller.paused ? 0.6 : 1
    }
    private var background: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(min(max(backgroundOpacity, CaptionOverlay.opacityRange.lowerBound), CaptionOverlay.opacityRange.upperBound)))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(overlay.hovering && !overlay.clickThrough ? 0.3 : 0), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .overlay { CaptionDragArea { overlay.drag(with: $0) } }
    }
    private var quietStatus: some View {
        HStack(spacing: 6) {
            RecordingDot(paused: controller.paused, elapsed: controller.elapsed, size: 7)
            Text(controller.paused ? "已暂停" : timestamp(controller.elapsed))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            if controller.sendingVoice {
                Text("译音发送中").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(accent, in: Capsule())
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .allowsHitTesting(false)
    }
    private var lockBadge: some View {
        HStack(spacing: 6) {
            if overlay.hoveringBadge {
                Text("点击解除鼠标穿透").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.7), in: Capsule())
            }
            Button { overlay.clickThrough = false } label: {
                Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(.black.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(overlay.hoveringBadge ? 1 : 0.5)
            .accessibilityLabel("解除鼠标穿透")
        }
    }
    private var resizeGrip: some View {
        Path { path in
            for offset in [4.0, 8.0] {
                path.move(to: CGPoint(x: 12, y: offset)); path.addLine(to: CGPoint(x: offset, y: 12))
            }
        }
        .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 14, height: 14)
        .padding(6)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { _ in overlay.resize() }
            .onEnded { _ in overlay.endDrag() })
        .help("拖动调整大小")
    }
}

/// Newest captions sit at the bottom; older lines scroll off the top under a fade.
struct CaptionStack: View {
    let segments: [TranscriptSegment]
    let fontSize: Double
    let showOriginal: Bool
    let placeholder: String
    var body: some View {
        GeometryReader { proxy in
            if segments.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize * 0.7, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.85), radius: 2.5, x: 0, y: 1)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                VStack(alignment: .leading, spacing: fontSize * 0.5) {
                    ForEach(segments) { segment in
                        CaptionLine(segment: segment, fontSize: fontSize, showOriginal: showOriginal)
                            .opacity(segment.id == segments.last?.id ? 1 : 0.72)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            }
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3),
                                     .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

struct CaptionLine: View {
    let segment: TranscriptSegment
    let fontSize: Double
    var showOriginal = true
    var body: some View {
        Group {
            if segment.source == .microphone {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("我").font(.system(size: fontSize * 0.46, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(accent, in: Capsule())
                    Text(segment.text).font(.system(size: fontSize * 0.68, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
            } else {
                VStack(alignment: .leading, spacing: fontSize * 0.14) {
                    Text(segment.primaryText).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(.white)
                    if showOriginal, let original = segment.secondaryText {
                        Text(original).font(.system(size: fontSize * 0.6)).foregroundStyle(.white.opacity(0.72))
                    }
                }
            }
        }
        .lineSpacing(fontSize * 0.1)
        .shadow(color: .black.opacity(0.85), radius: 2.5, x: 0, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CaptionToolbar: View {
    @ObservedObject var overlay: CaptionOverlay
    @ObservedObject var controller: MeetingController
    @Binding var backgroundOpacity: Double
    @Binding var fontSize: Double
    @Binding var showOriginal: Bool
    @Binding var showMine: Bool

    var body: some View {
        // Drop the least important controls first when the panel is narrow.
        ViewThatFits(in: .horizontal) {
            row(slider: true, toggles: true)
            row(slider: false, toggles: true)
            row(slider: false, toggles: false)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background { CaptionDragArea { overlay.drag(with: $0) } }
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(6)
    }

    private func row(slider: Bool, toggles: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 24, height: 24)
                .overlay { CaptionDragArea { overlay.drag(with: $0) } }
                .help("拖动移动悬浮字幕").accessibilityLabel("拖动移动悬浮字幕")
            RecordingDot(paused: controller.paused, elapsed: controller.elapsed, size: 7).padding(.leading, 4)
            Text(timestamp(controller.elapsed)).font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85)).padding(.trailing, 4)
            iconButton(controller.paused ? "play.fill" : "pause.fill", help: controller.paused ? "继续记录" : "暂停记录") {
                controller.togglePause()
            }
            iconButton(voiceIcon, help: voiceHelp, tint: voiceTint) { controller.toggleVoice() }
                .disabled(controller.paused)
            Button { overlay.endMeeting() } label: {
                Text("结束").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 24).background(Color.red.opacity(0.85), in: Capsule())
            }
            .buttonStyle(.plain).help("结束会议并生成总结").padding(.leading, 4)
            Spacer(minLength: 12)
            iconButton("textformat.size.smaller", help: "缩小字号") { fontSize = max(CaptionOverlay.fontRange.lowerBound, fontSize - 2) }
            iconButton("textformat.size.larger", help: "放大字号") { fontSize = min(CaptionOverlay.fontRange.upperBound, fontSize + 2) }
            if slider {
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    Slider(value: $backgroundOpacity, in: CaptionOverlay.opacityRange).controlSize(.mini).frame(width: 70)
                }
                .help("背景不透明度").padding(.horizontal, 4)
            }
            if toggles {
                iconButton("character.bubble", help: showOriginal ? "隐藏原文" : "显示原文", tint: showOriginal ? .white.opacity(0.2) : nil) { showOriginal.toggle() }
                iconButton("person.wave.2", help: showMine ? "隐藏我的发言" : "显示我的发言", tint: showMine ? .white.opacity(0.2) : nil) { showMine.toggle() }
            }
            divider
            iconButton("macwindow", help: "打开主窗口") { overlay.openMainWindow() }
            iconButton("lock.open", help: "鼠标穿透：点击直接落到下层的会议窗口") { overlay.clickThrough = true }
            iconButton("xmark", help: "隐藏悬浮字幕，可在主窗口重新打开") { overlay.hide() }
        }
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16).padding(.horizontal, 3) }
    private var voiceIcon: String { controller.voiceNeedsRouteRestore ? "mic.fill" : (controller.sendingVoice ? "waveform.circle.fill" : "waveform") }
    private var voiceHelp: String { controller.voiceNeedsRouteRestore ? "恢复原麦克风" : (controller.sendingVoice ? "停止发送译音" : "发送我的译音") }
    private var voiceTint: Color? { controller.voiceNeedsRouteRestore ? .orange : (controller.sendingVoice ? accent : nil) }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .background(tint ?? .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
