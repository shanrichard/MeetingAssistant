import Foundation

public final class MeetingStore {
    public let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingAssistant/Meetings", isDirectory: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    }
    public func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func save(_ meeting: Meeting) throws {
        let directory = folder(meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("meeting.json")
        try encoder.encode(meeting).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func load(_ id: UUID) throws -> Meeting {
        try decoder.decode(Meeting.self, from: Data(contentsOf: folder(id).appendingPathComponent("meeting.json")))
    }
    public func delete(_ id: UUID) throws {
        // The directory owns the transcript, recordings, summary and speaker references.
        do { try FileManager.default.removeItem(at: folder(id)) }
        catch CocoaError.fileNoSuchFile { return } // Already removed outside the app.
    }
    public func all() throws -> [Meeting] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { url -> Meeting? in
                guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
                return try? load(id)
            }.sorted { $0.createdAt > $1.createdAt }
    }
    public func recover(_ meeting: inout Meeting) throws {
        guard ["recording", "paused", "processing"].contains(meeting.state) else { return }
        meeting.state = "interrupted"
        meeting.addNotice("上次未正常结束。录音和实时原文已保留，可根据已有实时原文生成总结。")
        let files = try FileManager.default.contentsOfDirectory(at: folder(meeting.id), includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "wav" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count == 2, let source = AudioSource(rawValue: String(parts[0])), let ms = Double(parts[1]) else { continue }
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 44 else { continue }
            // A crash may leave a placeholder header; repair it from the durable PCM bytes.
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: WAV.header(byteCount: size - 44)); try handle.close()
            let chunk = AudioChunk(filename: file.lastPathComponent, source: source, start: ms / 1000,
                                   duration: Double(size - 44) / 48000)
            if let i = meeting.chunks.firstIndex(where: { $0.filename == chunk.filename }) { meeting.chunks[i] = chunk }
            else { meeting.chunks.append(chunk) }
            meeting.duration = max(meeting.duration, chunk.start + chunk.duration)
        }
        try save(meeting)
    }
}
