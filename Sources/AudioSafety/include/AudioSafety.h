#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVFoundation can raise NSException for device/configuration changes. Catch at the Objective-C
/// call site: unwinding an Objective-C exception through Swift frames is unsafe.
@interface AudioSafety : NSObject
+ (BOOL)configureCapture:(AVCaptureSession *)session deviceUID:(NSString *)deviceUID
                 output:(AVCaptureAudioDataOutput *)output error:(NSError **)error
    NS_SWIFT_NAME(configureCapture(_:deviceUID:output:));
+ (BOOL)startCapture:(AVCaptureSession *)session error:(NSError **)error
    NS_SWIFT_NAME(startCapture(_:));
+ (void)stopCapture:(AVCaptureSession *)session NS_SWIFT_NAME(stopCapture(_:));
+ (BOOL)startPlayback:(AVAudioEngine *)engine player:(AVAudioPlayerNode *)player
        outputFormat:(AVAudioFormat *)format error:(NSError **)error
    NS_SWIFT_NAME(startPlayback(_:player:outputFormat:));
+ (void)stopPlayback:(AVAudioEngine *)engine player:(AVAudioPlayerNode *)player
    NS_SWIFT_NAME(stopPlayback(_:player:));
@end

NS_ASSUME_NONNULL_END
