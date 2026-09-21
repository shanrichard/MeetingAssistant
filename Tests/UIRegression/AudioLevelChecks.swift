import Foundation
import Combine

@MainActor func checkAudioLevelIsolation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingMeterChecks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = MeetingController(storageRoot: folder)
    var wholeWindowUpdates = 0, meterUpdates = 0
    let window = controller.objectWillChange.sink { wholeWindowUpdates += 1 }
    let meter = controller.audioLevels.objectWillChange.sink { meterUpdates += 1 }
    for index in 0..<500 {
        controller.micLevel = Double(index % 100) / 100
        controller.systemLevel = Double(index % 50) / 50
    }
    guard wholeWindowUpdates == 0, meterUpdates == 1000 else {
        throw NSError(domain: "MeetingMeterChecks", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Audio meters invalidated the whole meeting window"])
    }
    withExtendedLifetime((window, meter)) {}
    print("Audio meter isolation: 1000 meter updates, 0 whole-window invalidations")
}
