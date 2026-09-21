import Foundation
import CoreAudio
import MeetingCore

/// Owns only the system input change made by this session. Capture remains bound
/// to its physical microphone UID; the output and alert devices are never changed.
@MainActor final class MicrophoneRoute {
    private struct SavedRoute: Codable {
        let originalUID: String
        let virtualUID: String
    }
    private let journal: URL
    private let listDevices: () throws -> [AudioDevice]
    private let defaultInput: () throws -> AudioObjectID
    private let setDefaultInput: (AudioDevice) throws -> Void
    private var selectedUID: String?
    var active: Bool { selectedUID != nil }

    init(journal: URL,
         listDevices: @escaping () throws -> [AudioDevice] = { try AudioDevices.list() },
         defaultInput: @escaping () throws -> AudioObjectID = { try AudioDevices.defaultInput() },
         setDefaultInput: @escaping (AudioDevice) throws -> Void = { try AudioDevices.setDefaultInput($0) }) {
        self.journal = journal; self.listDevices = listDevices
        self.defaultInput = defaultInput; self.setDefaultInput = setDefaultInput
    }

    func start(device: AudioDevice) throws {
        guard !active else { throw MeetingError.message("会议麦克风已由同传接管。") }
        // Retry any restoration left by an interrupted/failed previous session.
        try restore()
        let devices = try listDevices()
        guard let target = devices.first(where: { $0.uid == device.uid && $0.virtual && $0.input && $0.output }) else {
            throw MeetingError.message("同传需要同时具有输入和输出的虚拟麦克风。")
        }
        let originalID = try defaultInput()
        guard let original = devices.first(where: { $0.id == originalID && $0.input }) else {
            throw MeetingError.message("无法确认原麦克风，未开启同传。")
        }
        if original.uid != target.uid {
            // Persist before touching HAL, so the next launch can recover a crash.
            let saved = SavedRoute(originalUID: original.uid, virtualUID: target.uid)
            try JSONEncoder().encode(saved).write(to: journal, options: .atomic)
            do {
                try setDefaultInput(target)
                guard try defaultInput() == target.id else {
                    throw MeetingError.message("麦克风未切换到译音设备，未开启同传。")
                }
            } catch {
                let failure = error.localizedDescription
                do { try restore() }
                catch { throw MeetingError.message("\(failure)；\(error.localizedDescription)") }
                throw MeetingError.message(failure)
            }
        }
        selectedUID = target.uid
    }

    func validate() throws {
        guard let selectedUID else { return }
        let id = try defaultInput()
        guard try listDevices().contains(where: { $0.id == id && $0.uid == selectedUID && $0.input && $0.output }) else {
            throw MeetingError.message("会议麦克风已切离译音设备，同传已停止；通话可能正在发送原声。")
        }
    }

    /// Also called at launch. Never overwrite a more recent user/device choice.
    func restore() throws {
        selectedUID = nil
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let saved = try JSONDecoder().decode(SavedRoute.self, from: Data(contentsOf: journal))
        let devices = try listDevices(), id = try defaultInput()
        if let current = devices.first(where: { $0.id == id }), current.uid == saved.virtualUID {
            guard let original = devices.first(where: { $0.uid == saved.originalUID && $0.input }) else {
                throw MeetingError.message("原麦克风未连接，暂时无法恢复。请重新连接，或在系统声音设置中选择麦克风。")
            }
            try setDefaultInput(original)
            guard try defaultInput() == original.id else {
                throw MeetingError.message("原麦克风恢复未成功，请在系统声音设置中检查输入设备。")
            }
        } else if !devices.contains(where: { $0.id == id && $0.input }) {
            // An unresolvable route isn't evidence that someone changed it.
            throw MeetingError.message("暂时无法读取系统麦克风，恢复记录已保留。")
        }
        try FileManager.default.removeItem(at: journal)
    }
}
