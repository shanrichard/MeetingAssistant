import SwiftUI
import AppKit
import MeetingCore

struct TranscriptTimeline: View {
    let segments: [TranscriptSegment]
    let meeting: Meeting
    var title: String?
    let isLive: Bool
    let search: String
    let evidenceID: String?
    var notices: [String] = []
    var status = ""
    @State private var following = true
    @State private var revision = 0
    private let bottomID = "transcript-bottom"
    private var filtered: [TranscriptSegment] {
        segments.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || ($0.translation ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if isLive { Text(following && search.isEmpty ? "跟随最新" : "浏览中").font(.caption2).foregroundStyle(.secondary) }
                }.padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filtered.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "waveform").font(.title)
                                Text(!search.isEmpty ? "没有匹配的发言" : (isLive ? "正在录音，尚未收到字幕" : "还没有转写记录"))
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 50)
                        }
                        ForEach(filtered) { segment in
                            TranscriptCard(segment: segment, speaker: meeting.speaker(for: segment)).id(segment.id)
                        }
                        ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                            Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).padding(10)
                        }
                        Color.clear.frame(height: 12).id(bottomID)
                    }.padding(.horizontal, 8)
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
            if isLive {
                Text(status.isEmpty ? "正在连接实时同传…" : status)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(status)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 7)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
