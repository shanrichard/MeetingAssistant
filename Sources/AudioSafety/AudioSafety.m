#import "AudioSafety.h"

static void SetAudioError(NSError **error, NSException *exception) {
    if (error) {
        *error = [NSError errorWithDomain:@"com.meetingassistant.audio" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"麦克风音频设备正在切换或格式暂时不可用。请等待耳机连接稳定后重试，或在设置中选择 Mac 内置麦克风。",
                NSDebugDescriptionErrorKey: exception.reason ?: exception.name}];
    }
}

@implementation AudioSafety
+ (BOOL)configureCapture:(AVCaptureSession *)session deviceUID:(NSString *)deviceUID
                 output:(AVCaptureAudioDataOutput *)output error:(NSError **)error {
    @try {
        AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:deviceUID];
        if (!device) {
            if (error) *error = [NSError errorWithDomain:@"com.meetingassistant.audio" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"所选麦克风已断开，请在设置中重新选择。"}];
            return NO;
        }
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:error];
        if (!input) return NO;
        [session beginConfiguration];
        @try {
            if (![session canAddInput:input] || ![session canAddOutput:output]) {
                [NSException raise:NSInvalidArgumentException format:@"Microphone capture connection unavailable"];
            }
            [session addInput:input];
            [session addOutput:output];
        } @finally { [session commitConfiguration]; }
        return YES;
    } @catch (NSException *exception) { SetAudioError(error, exception); return NO; }
}
+ (BOOL)startCapture:(AVCaptureSession *)session error:(NSError **)error {
    @try {
        [session startRunning];
        if (!session.isRunning) {
            if (error) *error = [NSError errorWithDomain:@"com.meetingassistant.audio" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"麦克风采集未启动，请检查所选设备后重试。"}];
        }
        return session.isRunning;
    } @catch (NSException *exception) { SetAudioError(error, exception); return NO; }
}
+ (void)stopCapture:(AVCaptureSession *)session {
    @try { [session stopRunning]; } @catch (NSException *exception) {}
}
+ (BOOL)startPlayback:(AVAudioEngine *)engine player:(AVAudioPlayerNode *)player
        outputFormat:(AVAudioFormat *)format error:(NSError **)error {
    @try {
        AVAudioFormat *pcm = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:24000 channels:1];
        // The player keeps the model's PCM format; the mixer follows the current
        // hardware format, which may change while the virtual device starts.
        [engine connect:player to:engine.mainMixerNode format:pcm];
        [engine connect:engine.mainMixerNode to:engine.outputNode format:format];
        if (![engine startAndReturnError:error]) return NO;
        [player play];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"com.meetingassistant.audio" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"虚拟音频设备正在重配置，暂时无法启动译音输出。",
                       NSDebugDescriptionErrorKey: exception.reason ?: exception.name}];
        return NO;
    }
}
+ (void)stopPlayback:(AVAudioEngine *)engine player:(AVAudioPlayerNode *)player {
    @try { [player stop]; } @catch (NSException *exception) {}
    @try { [engine stop]; } @catch (NSException *exception) {}
}
@end
