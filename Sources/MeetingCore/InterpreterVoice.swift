import Foundation

/// Built-in voices documented for GPT-Live. Regional style is not a language restriction.
/// https://developers.openai.com/api/docs/guides/live-conversations#voice-options
public enum InterpreterVoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case marin, quartz, ripple, vesper, willow, stone, gleam, meridian, bossa, tempo, beacon, delta, cinder

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
    public var label: String {
        switch self {
        case .marin: return "Marin（默认）"
        case .quartz: return "Quartz · 女声 · 澳大利亚"
        case .ripple: return "Ripple · 男声 · 澳大利亚"
        case .vesper: return "Vesper · 男声 · 英国"
        case .willow: return "Willow · 女声 · 爱尔兰"
        case .stone: return "Stone · 男声 · 爱尔兰"
        case .gleam: return "Gleam · 女声 · 北美"
        case .meridian: return "Meridian · 男声 · 北美"
        case .bossa: return "Bossa · 女声 · 巴西"
        case .tempo: return "Tempo · 男声 · 巴西"
        case .beacon: return "Beacon · 男声 · 菲律宾"
        case .delta: return "Delta · 女声 · 美国南部"
        case .cinder: return "Cinder · 男声 · 美国南部"
        }
    }
}
