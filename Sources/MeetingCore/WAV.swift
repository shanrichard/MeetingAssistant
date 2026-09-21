import Foundation

public enum WAV {
    public static let sampleRate = 24000
    public static func header(byteCount: Int) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(byteCount + 36)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(24000); u32(48000); u16(2); u16(16); text("data"); u32(UInt32(byteCount))
        return data
    }
    public static func wrap(_ pcm: Data) -> Data { header(byteCount: pcm.count) + pcm }
    public static func clip(file: URL, start: Double, duration: Double) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(44 + max(0, Int(start * 24000)) * 2))
        let pcm = try handle.read(upToCount: max(0, Int(duration * 24000)) * 2) ?? Data()
        return wrap(pcm)
    }
}

/// Called only on the capture's serial processing queue. Timestamps refer to a shared host clock.
public final class ChunkRecorder {
    private let folder: URL
    private let source: AudioSource
    private let maxBytes: Int
    private var handle: FileHandle?
    private var chunkStart = 0.0
    private var bytes = 0
    private var filename = ""
    private let onChunk: (AudioChunk) -> Void
    public init(folder: URL, source: AudioSource, chunkSeconds: Double = 300, onChunk: @escaping (AudioChunk) -> Void) {
        self.folder = folder; self.source = source; maxBytes = Int(chunkSeconds * 24000) * 2; self.onChunk = onChunk
    }
    public func append(_ pcm: Data, at time: Double) throws {
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { return }
        if handle != nil, abs(time - (chunkStart + Double(bytes) / 48000)) > 0.2 {
            try close() // Preserve pauses / interruptions as timeline gaps, not hours of synthetic silence.
        }
        var position = 0
        while position < pcm.count {
            if handle == nil { try open(at: time + Double(position) / 48000) }
            let count = min(maxBytes - bytes, pcm.count - position)
            try handle?.write(contentsOf: pcm.subdata(in: position..<(position + count)))
            bytes += count; position += count
            if bytes >= maxBytes { try close() }
        }
    }
    private func open(at time: Double) throws {
        chunkStart = max(0, time); bytes = 0
        filename = "\(source.rawValue)_\(Int((chunkStart * 1000).rounded())).wav"
        let url = folder.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw MeetingError.message("录音时间片冲突，停止以保护已有音频。") }
        guard FileManager.default.createFile(atPath: url.path, contents: WAV.header(byteCount: 0), attributes: [.posixPermissions: 0o600]) else {
            throw MeetingError.message("无法创建录音文件，请检查磁盘空间。")
        }
        handle = try FileHandle(forWritingTo: url); try handle?.seekToEnd()
    }
    public func close() throws {
        guard let handle else { return }
        self.handle = nil
        try handle.seek(toOffset: 0); try handle.write(contentsOf: WAV.header(byteCount: bytes))
        try handle.synchronize(); try handle.close()
        onChunk(AudioChunk(filename: filename, source: source, start: chunkStart, duration: Double(bytes) / 48000))
    }
    deinit { try? close() }
}
