#import <AudioSafety.h>

// No recording, network, or user data: this double only exercises the ObjC boundary.
@interface TestCaptureSession : NSObject
@property BOOL shouldThrow;
@property BOOL shouldFail;
@property BOOL stopped;
@property BOOL isRunning;
@end
@implementation TestCaptureSession
- (void)startRunning {
    if (self.shouldThrow) [NSException raise:NSInvalidArgumentException format:@"device changed"];
    self.isRunning = !self.shouldFail;
}
- (void)stopRunning {
    self.stopped = YES; self.isRunning = NO;
    if (self.shouldThrow) [NSException raise:NSInvalidArgumentException format:@"device removed"];
}
@end

@interface TestPlaybackEngine : NSObject
@property BOOL shouldThrow;
@property BOOL shouldFail;
@property BOOL stopped;
@end
@implementation TestPlaybackEngine
- (id)mainMixerNode { return self; }
- (id)outputNode { return self; }
- (void)connect:(id)source to:(id)destination format:(AVAudioFormat *)format {
    if (self.shouldThrow) [NSException raise:NSInvalidArgumentException format:@"format changed"];
}
- (BOOL)startAndReturnError:(NSError **)error {
    if (self.shouldFail && error) *error = [NSError errorWithDomain:@"test" code:42 userInfo:nil];
    return !self.shouldFail;
}
- (void)stop { self.stopped = YES; }
@end

@interface TestPlaybackPlayer : NSObject
@property BOOL playing;
@property BOOL shouldThrow;
@end
@implementation TestPlaybackPlayer
- (void)play { self.playing = YES; }
- (void)stop {
    self.playing = NO;
    if (self.shouldThrow) [NSException raise:NSInvalidArgumentException format:@"player reset"];
}
@end

static int checks, failures;
static void Check(BOOL result, NSString *name) {
    checks++;
    if (!result) { failures++; fprintf(stderr, "FAIL: %s\n", name.UTF8String); }
}

int main(void) {
    @autoreleasepool {
        TestCaptureSession *session = [TestCaptureSession new];
        NSError *error = nil;
        Check([AudioSafety startCapture:(id)session error:&error], @"capture starts");
        Check(error == nil && session.isRunning, @"success leaves no error");
        [AudioSafety stopCapture:(id)session];
        Check(session.stopped && !session.isRunning, @"capture stops");
        session.shouldFail = YES;
        Check(![AudioSafety startCapture:(id)session error:&error], @"silent startup failure rejected");
        Check(error.code == 3, @"startup error is returned");
        session.shouldThrow = YES;
        Check(![AudioSafety startCapture:(id)session error:&error], @"startup exception contained");
        Check([error.domain isEqualToString:@"com.meetingassistant.audio"] && [error.localizedDescription containsString:@"重试"], @"recoverable error");
        Check(![AudioSafety startCapture:(id)session error:NULL], @"optional error pointer supported");
        session.stopped = NO;
        [AudioSafety stopCapture:(id)session];
        Check(session.stopped, @"cleanup exception contained");
        AVCaptureSession *realSession = [AVCaptureSession new];
        AVCaptureAudioDataOutput *output = [AVCaptureAudioDataOutput new];
        Check(![AudioSafety configureCapture:realSession deviceUID:@"com.meetingassistant.tests.nonexistent-microphone" output:output error:&error], @"missing device rejected without recording");
        Check(error.code == 2, @"missing device error is returned");
        TestPlaybackEngine *engine = [TestPlaybackEngine new];
        TestPlaybackPlayer *player = [TestPlaybackPlayer new];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        error = nil;
        Check([AudioSafety startPlayback:(id)engine player:(id)player outputFormat:format error:&error], @"playback starts");
        Check(player.playing && error == nil, @"player starts only after engine success");
        [AudioSafety stopPlayback:(id)engine player:(id)player];
        Check(!player.playing && engine.stopped, @"playback cleanup");
        engine.shouldFail = YES;
        Check(![AudioSafety startPlayback:(id)engine player:(id)player outputFormat:format error:&error], @"engine start failure returned");
        Check(error.code == 42 && !player.playing, @"engine error preserved without starting player");
        engine.shouldThrow = YES;
        Check(![AudioSafety startPlayback:(id)engine player:(id)player outputFormat:format error:&error], @"format exception contained");
        Check(error.code == 4, @"playback error returned for recovery");
        Check(![AudioSafety startPlayback:(id)engine player:(id)player outputFormat:format error:NULL], @"playback optional error pointer");
        engine.stopped = NO; player.shouldThrow = YES;
        [AudioSafety stopPlayback:(id)engine player:(id)player];
        Check(engine.stopped, @"engine stops even if player cleanup throws");
        printf("%d audio exception checks, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
}
