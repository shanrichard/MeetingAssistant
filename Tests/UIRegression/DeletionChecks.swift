import Foundation
import MeetingCore

// Exercise the real controller against synthetic local data, without capture or API work.
@MainActor func checkMeetingDeletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDeletionChecks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(root: root)
    var meetings = (1...3).map { Meeting(title: "Synthetic meeting \($0)") }
    for index in meetings.indices { meetings[index].state = "complete"; try store.save(meetings[index]) }
    let controller = MeetingController(storageRoot: root)
    controller.meetings = meetings
    controller.selectedID = meetings[1].id
    controller.error = nil
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw MeetingError.message(message) }
    }
    for state in ["starting", "recording", "processing"] {
        controller.starting = state == "starting"
        controller.recording = state == "recording"
        controller.processing = state == "processing"
        controller.deleteMeeting(meetings[1].id)
        try check(controller.meetings.count == 3 && controller.selectedID == meetings[1].id, "Busy deletion changed the UI")
        try check(try store.all().count == 3, "Busy deletion removed stored data")
    }
    controller.starting = false; controller.recording = false; controller.processing = false

    // A filesystem failure must surface an error and preserve the displayed meeting/selection.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    controller.deleteMeeting(meetings[1].id)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try check(controller.error?.hasPrefix("删除会议失败：") == true, "Missing deletion error")
    try check(controller.meetings.count == 3 && controller.selectedID == meetings[1].id, "Failed deletion changed the UI")
    controller.error = nil

    controller.deleteMeeting(meetings[0].id)
    try check(controller.selectedID == meetings[1].id, "Deleting another row changed selection")
    try check(controller.meetings.map(\.id) == [meetings[1].id, meetings[2].id], "Wrong row deleted")
    controller.deleteMeeting(meetings[1].id)
    try check(controller.selectedID == meetings[2].id && controller.current?.id == meetings[2].id, "Selected deletion did not select the next row")
    controller.deleteMeeting(meetings[2].id)
    try check(controller.meetings.isEmpty && controller.selectedID == nil && controller.current == nil, "Last deletion did not restore the welcome view")
    try check(try store.all().isEmpty, "Deleted meeting reappeared on reload")

    for meeting in meetings { try store.save(meeting) }
    controller.meetings = meetings; controller.selectedID = meetings[2].id
    controller.deleteMeeting(meetings[2].id)
    try check(controller.selectedID == meetings[1].id, "Last row deletion did not select the previous row")
    try store.delete(meetings[1].id)
    controller.deleteMeeting(meetings[1].id)
    try check(controller.meetings.map(\.id) == [meetings[0].id] && controller.error == nil, "Externally removed meeting could not be cleared")
    print("Meeting deletion: \(checks) assertions, 0 failures")
}
