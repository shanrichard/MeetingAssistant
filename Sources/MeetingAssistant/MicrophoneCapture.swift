import Foundation
import AVFoundation
import AudioSafety
import MeetingCore

/// Uses the capture service's device routing instead of manually reconfiguring
/// AVAudioEngine's HAL unit when a Bluetooth microphone changes profile.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue: DispatchQueue
    private let onBuffer: (AVAudioPCMBuffer, UInt64) -> Void
    private let onFailure: (String) -> Void
    private var notifications: [NSObjectProtocol] = []

    init(queue: DispatchQueue, onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void, onFailure: @escaping (String) -> Void) {
        self.queue = queue; self.onBuffer = onBuffer; self.onFailure = onFailure
        super.init()
    }

    func start(deviceUID: String) throws {
        output.setSampleBufferDelegate(self, queue: queue)
        try AudioSafety.configureCapture(session, deviceUID: deviceUID, output: output)
        for name in [Notification.Name.AVCaptureSessionRuntimeError, .AVCaptureSessionWasInterrupted] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.onFailure("麦克风采集中断，请检查设备连接后开始新会议。") }
            })
        }
        try AudioSafety.startCapture(session)
    }

    func stop() {
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        notifications.removeAll()
        AudioSafety.stopCapture(session)
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int(Int32.max),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { onFailure("无法读取麦克风音频（\(status)）。"); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime: UInt64
        if let clock = session.synchronizationClock {
            let seconds = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
            hostTime = seconds.isFinite && seconds >= 0 ? AVAudioTime.hostTime(forSeconds: seconds) : mach_absolute_time()
        } else { hostTime = mach_absolute_time() }
        onBuffer(buffer, hostTime)
    }
}
