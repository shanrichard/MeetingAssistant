import SwiftUI
import AppKit
import MeetingCore

struct TranscriptTimeline: View {
    let segments: [TranscriptSegment]
    let meeting: Meeting
    let isLive: Bool
    let search: String
    let evidenceID: String?
    var notices: [String] = []
    @State private var following = true
    @State private var revision = 0
    private let bottomID = "transcript-bottom"
    private var filtered: [TranscriptSegment] {
        segments.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || ($0.translation ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty { emptyState }
                    ForEach(filtered) { segment in
                        TranscriptCard(segment: segment, speaker: meeting.speaker(for: segment), highlighted: segment.id == evidenceID)
                            .id(segment.id)
                    }
                    if !notices.isEmpty { noticeList }
                    Color.clear.frame(height: 16).id(bottomID)
                }
                .frame(maxWidth: 880)
                .padding(.horizontal, 14).padding(.top, 6)
                .frame(maxWidth: .infinity)
                .background(ScrollFollowObserver { atBottom in following = atBottom })
            }
            .overlay(alignment: .bottomTrailing) {
                if isLive, !following, search.isEmpty {
                    Button { following = true; revision += 1 } label: { Label("回到最新", systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent).tint(accent).padding(16)
                }
            }
            .onAppear { if isLive { revision += 1 } }
            .onChange(of: segments) { _, _ in if isLive, following, search.isEmpty { revision += 1 } }
            .onChange(of: isLive) { _, live in if live { following = true; revision += 1 } }
            .onChange(of: search) { _, value in if value.isEmpty, following { revision += 1 } }
            .onChange(of: evidenceID) { _, id in
                if let id { following = false; reader.scrollTo(id, anchor: .center) }
            }
            .task(id: revision) {
                guard isLive, following, search.isEmpty else { return }
                // Let text wrapping and LazyVStack layout settle before scrolling to a stable end anchor.
                do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
                guard following, search.isEmpty else { return }
                reader.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: isLive ? "waveform" : "text.bubble").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(!search.isEmpty ? "没有匹配的发言" : (isLive ? "正在聆听，字幕会显示在这里" : "还没有转写记录"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var noticeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("记录说明").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 12)
    }
}

/// One speech segment: the translation leads, the original sits underneath, and my own speech recedes.
struct TranscriptCard: View {
    let segment: TranscriptSegment
    let speaker: String
    var highlighted = false
    private var isMine: Bool { segment.source == .microphone }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(timestamp(segment.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                Text(speaker).font(.system(size: 11, weight: .medium)).foregroundStyle(isMine ? accent : Color.secondary)
            }
            .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                if isMine {
                    Text(segment.text).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(2)
                } else {
                    Text(segment.primaryText)
                        .font(.system(size: segment.translation != nil ? 17 : 15, weight: .medium)).lineSpacing(3)
                    if let original = segment.secondaryText {
                        Text(original).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .background(highlighted ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Only user scroll gestures suspend following; growth caused by a new delta does not.
private struct ScrollFollowObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onScroll: onScroll) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.removeObservers() }

    final class ObserverView: NSView {
        var onScroll: (Bool) -> Void
        private weak var observed: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        init(onScroll: @escaping (Bool) -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard let scroll = enclosingScrollView, observed !== scroll else { return }
            removeObservers(); observed = scroll
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.onScroll(false)
            })
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observers.append(center.addObserver(forName: name, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                    guard let scroll, let document = scroll.documentView else { return }
                    self?.onScroll(document.bounds.maxY - scroll.contentView.bounds.maxY <= 40)
                })
            }
        }
        func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver); observers = []; observed = nil
        }
        deinit { removeObservers() }
    }
}
