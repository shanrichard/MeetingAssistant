import SwiftUI
import MeetingCore

/// Azure from the app icon; used for selection, links and the live captions accent.
let accent = Color(red: 0.17, green: 0.44, blue: 0.96)

extension TranscriptSegment {
    var hasCaptionText: Bool { hasText || !(translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    /// What people read first: the translation when one exists, otherwise the original.
    var primaryText: String {
        guard let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return translation
    }
    /// The original under a translation, only when it differs from the translation.
    var secondaryText: String? {
        guard hasText, let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              translation.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return text
    }
}

func durationText(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return seconds > 0 ? "不到 1 分钟" : "" }
    if minutes < 60 { return "\(minutes) 分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
}

func meetingStateName(_ state: String) -> String {
    ["recording": "录制中", "paused": "已暂停", "processing": "总结中", "recorded": "待总结", "interrupted": "待总结"][state] ?? state
}

/// Groups the newest-first library by how long ago each meeting happened.
func librarySection(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(date) { return "今天" }
    if calendar.isDateInYesterday(date) { return "昨天" }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
        return "过去 7 天"
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.wide)) }
    return date.formatted(.dateTime.year().month(.wide))
}

struct StateBadge: View {
    let state: String
    var body: some View {
        if state != "complete" {
            Text(meetingStateName(state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.14), in: Capsule())
        }
    }
    private var color: Color {
        switch state {
        case "recording": return .red
        case "paused", "recorded", "interrupted": return .orange
        default: return accent
        }
    }
}

/// Blinks with the once-per-second elapsed update instead of a continuous animation.
struct RecordingDot: View {
    let paused: Bool
    let elapsed: Double
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(paused ? Color.orange : Color.red)
            .frame(width: size, height: size)
            .opacity(paused || Int(elapsed) % 2 == 0 ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.45), value: Int(elapsed))
            .accessibilityLabel(paused ? "已暂停" : "正在记录")
    }
}

struct LevelMeter: View {
    let level: Double
    var width: CGFloat = 64
    var tint: Color = accent
    var body: some View {
        let value = min(1, max(0, level))
        Capsule().fill(.quaternary)
            .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: width * value) }
            .frame(width: width, height: 5)
            .accessibilityLabel("音量").accessibilityValue("\(Int(value * 100))%")
    }
}
