#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVCaptureDevice.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <sys/stat.h>
#import <math.h>

// No networking, entitlements, UIKit, or upload hooks. iOS 15+, arm64.
static char LVJobKey, LVInternalKey, LVRemoteConfigMarkerKey;
static __thread unsigned LVOriginalDepth;
static dispatch_queue_t LVLogQueue;
static NSMutableSet<NSString *> *LVInstalled;
static BOOL LVEnabled;

typedef void (^LVCompletion)(void);
static void LVDirectUpload(NSURL *fileURL, void (^done)(NSString *downloadURL));
typedef void (^LVFetchCompletion)(NSData *data, NSURLResponse *response, NSError *error);
static NSError *LVError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"LocketVideo17" code:code
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void LVLog(NSString *message) {
    if (!LVLogQueue) return;
    dispatch_async(LVLogQueue, ^{
        @autoreleasepool {
            NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            if (!dir) return;
            NSString *path = [dir stringByAppendingPathComponent:@"locket-video17.log"];
            NSFileManager *fm = NSFileManager.defaultManager;
            if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
            @try {
                NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
                if (!h) return;
                if ([h seekToEndOfFile] > 262144) { [h truncateFileAtOffset:0]; [h seekToFileOffset:0]; }
                NSString *line = [NSString stringWithFormat:@"%.0f %@\n", NSDate.date.timeIntervalSince1970, message];
                [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [h closeFile];
            } @catch (__unused NSException *e) { }
        }
    });
}
static BOOL LVFullVideo(AVAssetExportSession *s, CMTime *duration) {
    @try {
        if (!s.asset || s.asset.hasProtectedContent) return NO;
        CMTime d = s.asset.duration;
        double seconds = CMTimeGetSeconds(d);
        if (!CMTIME_IS_NUMERIC(d) || !isfinite(seconds) || seconds <= 0 ||
            [s.asset tracksWithMediaType:AVMediaTypeVideo].count == 0) return NO;
        if (duration) *duration = d;
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}
static int64_t LVSize(NSURL *url) {
    if (!url.isFileURL) return -1;
    const char *path = url.fileSystemRepresentation;
    struct stat info;
    // A reused NSURL may cache resource values across retries; always inspect the current file.
    if (!path || stat(path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) return -1;
    return (int64_t)info.st_size;
}
static NSInteger LVSourceChannels(AVAssetTrack *track) {
    for (id format in track.formatDescriptions) {
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)format);
        if (asbd && asbd->mChannelsPerFrame > 0) return MIN(2, (NSInteger)asbd->mChannelsPerFrame);
    }
    return 2;
}
// Quality target for the rare render-only path. Prefer the source track's own bitrate;
// use a resolution-based estimate when the container does not advertise one.
static NSInteger LVSourceVideoRate(AVAsset *asset) {
    double rate = 0;
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (track) {
        rate = track.estimatedDataRate;
        if (!isfinite(rate) || rate <= 0) {
            CGRect b = CGRectApplyAffineTransform((CGRect){CGPointZero, track.naturalSize}, track.preferredTransform);
            CGFloat edge = fmax(fabs(b.size.width), fabs(b.size.height));
            rate = edge >= 1920 ? 6000000 : (edge >= 1280 ? 3000000 : (edge >= 720 ? 1500000 : 800000));
        }
    }
    if (!isfinite(rate) || rate <= 0) rate = 3000000;
    return (NSInteger)fmin(12000000.0, fmax(500000.0, rate));
}
static NSString *LVOutputType(AVAssetExportSession *s) {
    NSString *ext = s.outputURL.pathExtension.lowercaseString;
    NSString *type = s.outputFileType;
    if (!type) {
        if ([ext isEqualToString:@"mp4"]) type = AVFileTypeMPEG4;
        else if ([ext isEqualToString:@"mov"]) type = AVFileTypeQuickTimeMovie;
        else if ([ext isEqualToString:@"m4v"]) type = AVFileTypeAppleM4V;
    }
    if (([type isEqualToString:AVFileTypeMPEG4] && [ext isEqualToString:@"mp4"]) ||
        ([type isEqualToString:AVFileTypeQuickTimeMovie] && [ext isEqualToString:@"mov"]) ||
        ([type isEqualToString:AVFileTypeAppleM4V] && [ext isEqualToString:@"m4v"])) return type;
    return nil;
}

@interface LV17Job : NSObject
@property(nonatomic, strong) AVAssetExportSession *owner;
@property(nonatomic, strong) AVAsset *asset;
@property(nonatomic, strong) NSURL *outputURL;
@property(nonatomic, copy) NSString *fileType;
@property(nonatomic, strong) AVVideoComposition *videoComposition;
@property(nonatomic, strong) AVAudioMix *audioMix;
@property(nonatomic, copy) NSArray<AVMetadataItem *> *metadata;
@property(nonatomic) CMTime duration;
@property(nonatomic) AVAssetExportSessionStatus state;
@property(nonatomic) float fraction;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL finished;
@property(nonatomic, strong) NSMutableArray<LVCompletion> *callbacks;
@property(nonatomic, strong) NSURL *temporaryDirectory;
- (void)run;
- (void)requestCancel;
- (void)complete:(NSURL *)temporary error:(NSError *)error;
- (BOOL)encode:(NSURL *)url videoRate:(NSInteger)rate audioRate:(NSInteger)audioRate
          hevc:(BOOL)hevc attempt:(NSUInteger)attempt error:(NSError **)error;
@end

@implementation LV17Job
- (BOOL)isCancelled { @synchronized(self) { return _cancelled; } }
- (void)requestCancel {
    @synchronized(self) { if (!_finished) _cancelled = YES; }
}
- (void)setWorkingProgress:(float)p {
    @synchronized(self) { if (!_finished) _fraction = fminf(.97f, fmaxf(0, p)); }
}
- (void)complete:(NSURL *)temporary error:(NSError *)error {
    NSArray<LVCompletion> *handlers;
    AVAssetExportSession *keepAlive;
    @synchronized(self) {
        if (_finished) return;
        if (_cancelled) error = LVError(NSUserCancelledError, @"Video export cancelled.");
        if (!error && !temporary) error = LVError(20, @"Missing export result.");
        if (!error) {
            NSError *moveError;
            // Never overwrite or remove an existing app-owned output.
            if (![NSFileManager.defaultManager moveItemAtURL:temporary toURL:_outputURL error:&moveError])
                error = LVError(21, @"Cannot publish the export (output must not already exist).");
            else
                LVDirectUpload(_outputURL, nil);
        }
        _failure = error;
        _state = _cancelled ? AVAssetExportSessionStatusCancelled :
                 (error ? AVAssetExportSessionStatusFailed : AVAssetExportSessionStatusCompleted);
        if (!error) _fraction = 1;
        _finished = YES;
        handlers = [_callbacks copy];
        [_callbacks removeAllObjects];
        keepAlive = _owner;
        _owner = nil; // Break session -> associated job -> session cycle after work.
    }
    if (_temporaryDirectory) [NSFileManager.defaultManager removeItemAtURL:_temporaryDirectory error:NULL];
    LVLog([NSString stringWithFormat:@"finish status=%ld code=%ld", (long)_state, (long)error.code]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        (void)keepAlive;
        for (LVCompletion callback in handlers) {
            @try { callback(); } @catch (__unused NSException *e) { LVLog(@"completion exception"); }
        }
    });
}
- (BOOL)validate:(NSURL *)url error:(NSError **)error {
    int64_t bytes = LVSize(url);
    if (bytes <= 0) {
        if (error) *error = LVError(30, @"Exported file is missing or is not a regular file.");
        return NO;
    }
    AVURLAsset *result = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    double expected = CMTimeGetSeconds(_duration), actual = CMTimeGetSeconds(result.duration);
    BOOL needsAudio = [_asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
    // Do not report success for a short output, even if a codec stopped early.
    if (!isfinite(actual) || fabs(actual - expected) > .30 ||
        [result tracksWithMediaType:AVMediaTypeVideo].count == 0 ||
        (needsAudio && [result tracksWithMediaType:AVMediaTypeAudio].count == 0)) {
        if (error) *error = LVError(31, @"Output failed full-duration/audio validation; no truncated file was published.");
        return NO;
    }
    LVLog([NSString stringWithFormat:@"validated seconds=%.3f bytes=%lld", actual, (long long)bytes]);
    return YES;
}
- (BOOL)canCopy:(NSURL **)source {
    if (![_asset isKindOfClass:AVURLAsset.class] || _videoComposition || _audioMix) return NO;
    NSURL *url = ((AVURLAsset *)_asset).URL;
    if (!url.isFileURL || [url isEqual:_outputURL]) return NO;
    int64_t size = LVSize(url);
    if (size <= 0) return NO;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    NSData *head = [h readDataOfLength:12];
    [h closeFile];
    if (head.length < 12) return NO;
    const uint8_t *b = head.bytes;
    if (memcmp(b + 4, "ftyp", 4) != 0) return NO;
    BOOL qt = memcmp(b + 8, "qt  ", 4) == 0;
    NSString *ext = url.pathExtension.lowercaseString;
    BOOL compatible = (qt && [_fileType isEqualToString:AVFileTypeQuickTimeMovie] && [ext isEqualToString:@"mov"]) ||
        (!qt && [_fileType isEqualToString:AVFileTypeMPEG4] && [ext isEqualToString:@"mp4"]) ||
        (!qt && [_fileType isEqualToString:AVFileTypeAppleM4V] && [ext isEqualToString:@"m4v"]);
    if (compatible && source) *source = url;
    return compatible;
}
- (void)run {
    @autoreleasepool {
        @try {
            @synchronized(self) { if (!_cancelled) _state = AVAssetExportSessionStatusExporting; }
            if (self.isCancelled) { [self complete:nil error:nil]; return; }
            NSError *error = nil;
            _temporaryDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                [@"lv17-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
            if (![NSFileManager.defaultManager createDirectoryAtURL:_temporaryDirectory
                 withIntermediateDirectories:YES attributes:nil error:&error]) {
                [self complete:nil error:LVError(22, @"Cannot create a private export directory.")]; return;
            }
            NSURL *temp = [_temporaryDirectory URLByAppendingPathComponent:
                           [@"export." stringByAppendingString:_outputURL.pathExtension]];
            NSURL *source;
            if ([self canCopy:&source]) {
                LVLog(@"copy compatible original");
                if (![NSFileManager.defaultManager copyItemAtURL:source toURL:temp error:&error]) {
                    [self complete:nil error:LVError(23, @"Cannot copy the source video.")]; return;
                }
                if ([self validate:temp error:&error]) { [self complete:temp error:nil]; return; }
                [NSFileManager.defaultManager removeItemAtURL:temp error:NULL];
            }
            // No re-encode budget: keep source quality. The direct upload path posts the file
            // with the app's own Firebase token instead of going through the app uploader.
            NSInteger rate = LVSourceVideoRate(_asset);
            BOOL audio = [_asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
            NSInteger audioRate = audio ? 128000 : 0;
            BOOL preferHEVC = YES;
            for (NSUInteger attempt = 0; attempt < 2; attempt++) {
                if (self.isCancelled) { [self complete:nil error:nil]; return; }
                BOOL ok = [self encode:temp videoRate:rate audioRate:audioRate hevc:preferHEVC attempt:attempt error:&error];
                if (!ok && preferHEVC && !self.isCancelled) {
                    LVLog(@"HEVC failed; retry H264");
                    [NSFileManager.defaultManager removeItemAtURL:temp error:NULL];
                    preferHEVC = NO;
                    ok = [self encode:temp videoRate:rate audioRate:audioRate hevc:NO attempt:attempt error:&error];
                }
                if (ok && [self validate:temp error:&error]) {
                    [self complete:temp error:nil]; return;
                }
                LVLog([NSString stringWithFormat:@"retry attempt=%lu bytes=%lld code=%ld",
                       (unsigned long)attempt, (long long)LVSize(temp), (long)error.code]);
                [NSFileManager.defaultManager removeItemAtURL:temp error:NULL];
            }
            [self complete:nil error:error ?: LVError(33, @"Cannot produce a valid full-length video output.")];
        } @catch (__unused NSException *e) {
            [self complete:nil error:LVError(24, @"AVFoundation raised an exception while exporting.")];
        }
    }
}

- (BOOL)encode:(NSURL *)url videoRate:(NSInteger)rate audioRate:(NSInteger)audioRate
          hevc:(BOOL)hevc attempt:(NSUInteger)attempt error:(NSError **)error {
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    NSArray<AVAssetTrack *> *videos = [_asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audios = [_asset tracksWithMediaType:AVMediaTypeAudio];
    if (!videos.count) { if (error) *error = LVError(40, @"No video track."); return NO; }
    double sourceFPS = videos.firstObject.nominalFrameRate;
    NSInteger fps = sourceFPS > 0 ? MIN(60, MAX(1, (NSInteger)llround(sourceFPS))) : 30;
    AVVideoComposition *composition = _videoComposition;
    CGSize renderSize;
    if (composition) {
        // App-provided compositions already define orientation/effects. Do not rewrite their instructions.
        renderSize = composition.renderSize;
    } else {
        AVAssetTrack *track = videos.firstObject;
        CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, track.naturalSize}, track.preferredTransform);
        CGFloat w = fabs(bounds.size.width), h = fabs(bounds.size.height);
        if (w < 2 || h < 2 || !isfinite(w) || !isfinite(h)) {
            if (error) *error = LVError(41, @"Invalid video dimensions."); return NO;
        }
        // Scale down when the byte budget is tight, so long videos stay under the server cap.
        NSInteger maxEdge = rate < 90000 ? 480 : (rate < 200000 ? 640 : (rate < 400000 ? 720 : 1080));
        CGFloat scale = fmin(1.0, (CGFloat)maxEdge / fmax(w, h));
        renderSize = CGSizeMake(MAX(2, (NSInteger)floor(w * scale / 2) * 2),
                                MAX(2, (NSInteger)floor(h * scale / 2) * 2));
        CGFloat sx = renderSize.width / w, sy = renderSize.height / h;
        CGAffineTransform t = track.preferredTransform;
        CGAffineTransform normalized = CGAffineTransformMake(t.a * sx, t.b * sy, t.c * sx, t.d * sy,
                                                             (t.tx - CGRectGetMinX(bounds)) * sx,
                                                             (t.ty - CGRectGetMinY(bounds)) * sy);
        AVMutableVideoComposition *c = [AVMutableVideoComposition videoComposition];
        c.renderSize = renderSize;
        c.frameDuration = CMTimeMake(1, (int32_t)fps);
        AVMutableVideoCompositionLayerInstruction *layer =
            [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
        [layer setTransform:normalized atTime:kCMTimeZero];
        AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange = CMTimeRangeMake(kCMTimeZero, _duration);
        instruction.layerInstructions = @[layer];
        c.instructions = @[instruction];
        composition = c;
    }
    if (renderSize.width < 2 || renderSize.height < 2 || !isfinite(renderSize.width) || !isfinite(renderSize.height)) {
        if (error) *error = LVError(41, @"Invalid composition dimensions."); return NO;
    }
    NSInteger width = MAX(2, (NSInteger)floor(renderSize.width / 2) * 2);
    NSInteger height = MAX(2, (NSInteger)floor(renderSize.height / 2) * 2);
    NSError *underlying = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:_asset error:&underlying];
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:_fileType error:&underlying];
    if (!reader || !writer) { if (error) *error = LVError(42, @"Cannot create reader/writer for this container."); return NO; }
    reader.timeRange = CMTimeRangeMake(kCMTimeZero, _duration);
    writer.shouldOptimizeForNetworkUse = YES;
    writer.metadata = _metadata ?: @[];
    AVAssetReaderVideoCompositionOutput *videoOut = [[AVAssetReaderVideoCompositionOutput alloc]
        initWithVideoTracks:(_videoComposition ? videos : @[videos.firstObject]) videoSettings:
            @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
    videoOut.videoComposition = composition;
    videoOut.alwaysCopiesSampleData = NO;
    NSDictionary *compression = @{
        AVVideoAverageBitRateKey:@(rate),
        AVVideoExpectedSourceFrameRateKey:@(fps),
        AVVideoMaxKeyFrameIntervalKey:@(fps * 4),
        AVVideoAllowFrameReorderingKey:@NO,
        AVVideoProfileLevelKey:hevc ? (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel : AVVideoProfileLevelH264MainAutoLevel
    };
    NSDictionary *videoSettings = @{
        AVVideoCodecKey:hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
        AVVideoWidthKey:@(width), AVVideoHeightKey:@(height),
        AVVideoScalingModeKey:AVVideoScalingModeResizeAspect,
        AVVideoCompressionPropertiesKey:compression
    };
    AVAssetWriterInput *videoIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    videoIn.expectsMediaDataInRealTime = NO;
    // Pixels are already oriented by the composition; writer's transform must remain identity.
    videoIn.transform = CGAffineTransformIdentity;
    if (![reader canAddOutput:videoOut] || ![writer canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo] ||
        ![writer canAddInput:videoIn]) {
        if (error) *error = LVError(43, @"Video encoder settings are unsupported."); return NO;
    }
    [reader addOutput:videoOut]; [writer addInput:videoIn];
    AVAssetReaderAudioMixOutput *audioOut = nil;
    AVAssetWriterInput *audioIn = nil;
    if (audios.count) {
        NSInteger channels = LVSourceChannels(audios.firstObject);
        NSInteger sampleRate = 44100;
        NSDictionary *pcm = @{AVFormatIDKey:@(kAudioFormatLinearPCM), AVSampleRateKey:@(sampleRate),
            AVNumberOfChannelsKey:@(channels), AVLinearPCMBitDepthKey:@16, AVLinearPCMIsFloatKey:@NO,
            AVLinearPCMIsBigEndianKey:@NO, AVLinearPCMIsNonInterleaved:@NO};
        audioOut = [[AVAssetReaderAudioMixOutput alloc] initWithAudioTracks:audios audioSettings:pcm];
        audioOut.audioMix = _audioMix;
        audioOut.alwaysCopiesSampleData = NO;
        NSDictionary *aac = @{AVFormatIDKey:@(kAudioFormatMPEG4AAC), AVSampleRateKey:@(sampleRate),
                              AVNumberOfChannelsKey:@(channels), AVEncoderBitRateKey:@(audioRate)};
        audioIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aac];
        audioIn.expectsMediaDataInRealTime = NO;
        if (![reader canAddOutput:audioOut] || ![writer canApplyOutputSettings:aac forMediaType:AVMediaTypeAudio] ||
            ![writer canAddInput:audioIn]) {
            if (error) *error = LVError(44, @"Audio encoder settings are unsupported; audio will not be silently dropped."); return NO;
        }
        [reader addOutput:audioOut]; [writer addInput:audioIn];
    }
    LVLog([NSString stringWithFormat:@"encode attempt=%lu seconds=%.3f video=%ld audio=%ld %ldx%ld %@",
           (unsigned long)attempt, CMTimeGetSeconds(_duration), (long)rate, (long)audioRate,
           (long)width, (long)height, hevc ? @"HEVC" : @"H264"]);
    if (![writer startWriting] || ![reader startReading]) {
        LVLog([NSString stringWithFormat:@"start failed reader=%ld writer=%ld", (long)reader.error.code, (long)writer.error.code]);
        [reader cancelReading]; [writer cancelWriting];
        if (error) *error = LVError(45, @"Cannot start the full-duration encoder."); return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    BOOL videoDone = NO, audioDone = audioOut == nil, failed = NO;
    NSUInteger videoSamples = 0, audioSamples = 0;
    double lastAdvance = NSProcessInfo.processInfo.systemUptime;
    double durationSeconds = CMTimeGetSeconds(_duration);
    [self setWorkingProgress:0];
    while (!videoDone || !audioDone) {
        @autoreleasepool {
            if (self.isCancelled || reader.status == AVAssetReaderStatusFailed ||
                reader.status == AVAssetReaderStatusCancelled || writer.status != AVAssetWriterStatusWriting) {
                failed = YES; break;
            }
            BOOL advanced = NO;
            if (!videoDone && videoIn.readyForMoreMediaData) {
                CMSampleBufferRef sample = [videoOut copyNextSampleBuffer];
                if (!sample) { [videoIn markAsFinished]; videoDone = YES; advanced = YES; }
                else {
                    double t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                    BOOL appended = [videoIn appendSampleBuffer:sample];
                    CFRelease(sample);
                    if (!appended) { failed = YES; break; }
                    videoSamples++; advanced = YES;
                    if (isfinite(t)) [self setWorkingProgress:(float)(.94 * fmax(0, t) / durationSeconds)];
                }
            }
            if (!audioDone && audioIn.readyForMoreMediaData) {
                CMSampleBufferRef sample = [audioOut copyNextSampleBuffer];
                if (!sample) { [audioIn markAsFinished]; audioDone = YES; advanced = YES; }
                else {
                    BOOL appended = [audioIn appendSampleBuffer:sample];
                    CFRelease(sample);
                    if (!appended) { failed = YES; break; }
                    audioSamples++; advanced = YES;
                }
            }
            double now = NSProcessInfo.processInfo.systemUptime;
            if (advanced) lastAdvance = now;
            else if (now - lastAdvance > 120) { failed = YES; break; }
            else usleep(2000); // Writer backpressure; interleave audio/video to avoid mux starvation.
        }
    }
    if (failed || !videoSamples || (audios.count && !audioSamples) || reader.status != AVAssetReaderStatusCompleted) {
        LVLog([NSString stringWithFormat:@"pipeline failed reader=%ld writer=%ld", (long)reader.error.code, (long)writer.error.code]);
        [reader cancelReading]; [writer cancelWriting];
        if (error) *error = LVError(46, @"The full-duration audio/video pipeline failed or was cancelled."); return NO;
    }
    [writer endSessionAtSourceTime:_duration];
    [self setWorkingProgress:.95];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    double finishStart = NSProcessInfo.processInfo.systemUptime;
    while (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4)) != 0) {
        if (self.isCancelled || NSProcessInfo.processInfo.systemUptime - finishStart > 120) {
            [writer cancelWriting];
            if (error) *error = LVError(47, @"Finishing the export was cancelled or timed out."); return NO;
        }
    }
    if (writer.status != AVAssetWriterStatusCompleted) {
        if (error) *error = LVError(48, @"The encoder did not finish successfully."); return NO;
    }
    return YES;
}
@end

static BOOL LVBypass(id session) {
    return !LVEnabled || LVOriginalDepth || objc_getAssociatedObject(session, &LVInternalKey) != nil;
}
static void LVExport(AVAssetExportSession *session, SEL selector, LVCompletion completion, IMP original) {
    CMTime duration;
    if (LVBypass(session)) {
        // Reentrant superclass calls must stay on the original path, not allocate another helper job.
        LVOriginalDepth++;
        @try { ((void (*)(id, SEL, LVCompletion))original)(session, selector, completion); }
        @finally { LVOriginalDepth--; }
        return;
    }
    LV17Job *job;
    @synchronized(session) {
        LV17Job *existing = objc_getAssociatedObject(session, &LVJobKey);
        if (existing) {
            @synchronized(existing) {
                if (!existing.finished) {
                    // A repeated start joins the current export; each supplied callback is delivered once.
                    if (completion) [existing.callbacks addObject:[completion copy]];
                    return;
                }
            }
            // An export session represents one operation. Never replace its terminal job/state,
            // including when a previous completion reenters before the callback batch has returned.
            if (completion) {
                LVCompletion callback = [completion copy];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    __attribute__((objc_precise_lifetime)) AVAssetExportSession *keepAlive = session;
                    @try { callback(); }
                    @catch (__unused NSException *e) { LVLog(@"completion exception"); }
                    (void)keepAlive;
                });
            }
            return;
        }
        if (!LVFullVideo(session, &duration)) {
            LVOriginalDepth++;
            @try { ((void (*)(id, SEL, LVCompletion))original)(session, selector, completion); }
            @finally { LVOriginalDepth--; }
            return;
        }
        job = [LV17Job new];
        job.owner = session; job.asset = session.asset; job.duration = duration;
        job.outputURL = session.outputURL; job.fileType = LVOutputType(session);
        job.videoComposition = session.videoComposition; job.audioMix = session.audioMix;
        job.metadata = session.metadata;
        job.callbacks = [NSMutableArray array];
        if (completion) [job.callbacks addObject:[completion copy]];
        job.state = AVAssetExportSessionStatusWaiting;
        objc_setAssociatedObject(session, &LVJobKey, job, OBJC_ASSOCIATION_RETAIN);
    }
    // Do not assign timeRange/fileLengthLimit here: both setters are swizzled and re-enter
    // LVFullVideo while the app is mid-upload, which crashed on video upload.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!job.outputURL.isFileURL || !job.fileType) {
            [job complete:nil error:LVError(50, @"A matching .mp4, .mov or .m4v local output URL/container is required.")];
        } else {
            [job run];
        }
    });
}

static BOOL LVOwnsSelector(Class cls, SEL selector, Method *result) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned i = 0; i < count; i++) {
        if (sel_isEqual(method_getName(methods[i]), selector)) {
            if (result) *result = methods[i];
            found = YES; break;
        }
    }
    free(methods);
    return found;
}
static void LVInstallOne(Class cls, SEL selector) {
    Method method;
    if (!LVOwnsSelector(cls, selector, &method)) return; // Never replace an inherited Method.
    NSString *key = [NSString stringWithFormat:@"%p:%s", cls, sel_getName(selector)];
    if ([LVInstalled containsObject:key]) return;
    IMP original = method_getImplementation(method);
    IMP replacement = NULL;
    if (sel_isEqual(selector, @selector(setTimeRange:))) {
        replacement = imp_implementationWithBlock(^(AVAssetExportSession *s, CMTimeRange range) {
            CMTime d;
            if (!LVBypass(s) && LVFullVideo(s, &d)) range = CMTimeRangeMake(kCMTimeZero, d);
            ((void (*)(id, SEL, CMTimeRange))original)(s, selector, range);
        });
    } else if (sel_isEqual(selector, @selector(setFileLengthLimit:))) {
        replacement = imp_implementationWithBlock(^(AVAssetExportSession *s, long long limit) {
            if (!LVBypass(s) && LVFullVideo(s, NULL)) limit = 0;
            ((void (*)(id, SEL, long long))original)(s, selector, limit);
        });
    } else if (sel_isEqual(selector, @selector(exportAsynchronouslyWithCompletionHandler:))) {
        replacement = imp_implementationWithBlock(^(AVAssetExportSession *s, LVCompletion completion) {
            LVExport(s, selector, completion, original);
        });
    } else if (sel_isEqual(selector, @selector(status))) {
        replacement = imp_implementationWithBlock(^AVAssetExportSessionStatus(AVAssetExportSession *s) {
            LV17Job *job = LVBypass(s) ? nil : objc_getAssociatedObject(s, &LVJobKey);
            if (job) { @synchronized(job) { return job.state; } }
            return ((AVAssetExportSessionStatus (*)(id, SEL))original)(s, selector);
        });
    } else if (sel_isEqual(selector, @selector(progress))) {
        replacement = imp_implementationWithBlock(^float(AVAssetExportSession *s) {
            LV17Job *job = LVBypass(s) ? nil : objc_getAssociatedObject(s, &LVJobKey);
            if (job) { @synchronized(job) { return job.fraction; } }
            return ((float (*)(id, SEL))original)(s, selector);
        });
    } else if (sel_isEqual(selector, @selector(error))) {
        replacement = imp_implementationWithBlock(^NSError *(AVAssetExportSession *s) {
            LV17Job *job = LVBypass(s) ? nil : objc_getAssociatedObject(s, &LVJobKey);
            if (job) { @synchronized(job) { return job.failure; } }
            return ((NSError *(*)(id, SEL))original)(s, selector);
        });
    } else if (sel_isEqual(selector, @selector(cancelExport))) {
        replacement = imp_implementationWithBlock(^(AVAssetExportSession *s) {
            LV17Job *job = LVBypass(s) ? nil : objc_getAssociatedObject(s, &LVJobKey);
            if (job) { [job requestCancel]; return; }
            LVOriginalDepth++;
            @try { ((void (*)(id, SEL))original)(s, selector); }
            @finally { LVOriginalDepth--; }
        });
    }
    if (replacement) {
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
        [LVInstalled addObject:key];
    }
}
static void LVInstallClasses(void) {
    @synchronized(LVInstalled) {
        Class base = AVAssetExportSession.class;
        unsigned count = 0;
        Class *classes = objc_copyClassList(&count);
        SEL selectors[] = {@selector(setTimeRange:), @selector(setFileLengthLimit:),
            @selector(exportAsynchronouslyWithCompletionHandler:), @selector(status),
            @selector(progress), @selector(error), @selector(cancelExport)};
        for (unsigned i = 0; i < count; i++) {
            Class cls = classes[i], cursor = cls;
            while (cursor && cursor != base) cursor = class_getSuperclass(cursor);
            if (cursor != base) continue;
            for (unsigned j = 0; j < sizeof(selectors) / sizeof(selectors[0]); j++) LVInstallOne(cls, selectors[j]);
        }
        free(classes);
        LVLog([NSString stringWithFormat:@"installed methods=%lu", (unsigned long)LVInstalled.count]);
    }
}
static __strong NSString *LVFirebaseToken;
static void LVStoreToken(NSString *token) {
    if (token.length < 20) return;
    @synchronized ([NSObject class]) {
        if (![token isEqualToString:LVFirebaseToken]) {
            LVFirebaseToken = [token copy];
            LVLog(@"token captured");
        }
    }
}
// Direct upload: POST the whole file to Firebase Storage, then let the app post the moment.
// Runs only after a successful export, using the token the app itself sent.
static void LVDirectUpload(NSURL *fileURL, void (^done)(NSString *downloadURL)) {
    NSString *token;
    @synchronized ([NSObject class]) { token = [LVFirebaseToken copy]; }
    if (!token) { LVLog(@"direct upload: no token"); if (done) done(nil); return; }
    UIDevice *dev = nil; (void)dev;
    NSString *name = [NSString stringWithFormat:@"users/%@/moments/videos/%@.mp4",
                      @"self", NSUUID.UUID.UUIDString];
    NSString *encoded = [name stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:
                     @"https://firebasestorage.googleapis.com/v0/b/locket-video/o?uploadType=media&name=%@", encoded];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"video/mp4" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 300;
    NSURLSessionUploadTask *task = [NSURLSession.sharedSession uploadTaskWithRequest:req fromFile:fileURL
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            LVLog([NSString stringWithFormat:@"direct upload code=%ld err=%ld bytes=%lu",
                   (long)code, (long)err.code, (unsigned long)data.length]);
            if (done) done(code == 200 ? @"ok" : nil);
        }];
    [task resume];
}
static void LVInstallUploaderChunkHook(void) {
    static BOOL tried;
    // Log every HTTP response the Firebase uploader receives: status line only, no body.
    if (!tried) {
        Class f = NSClassFromString(@"GTMSessionFetcher");
        SEL resp = NSSelectorFromString(@"setResponse:");
        Method m = f ? class_getInstanceMethod(f, resp) : NULL;
        if (m) {
            IMP o = method_getImplementation(m);
            IMP r = imp_implementationWithBlock(^(id self, NSURLResponse *response) {
                @try {
                    NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class]
                        ? ((NSHTTPURLResponse *)response).statusCode : 0;
                    NSString *us = nil;
                    if ([response isKindOfClass:NSHTTPURLResponse.class])
                        us = ((NSHTTPURLResponse *)response).allHeaderFields[@"X-Goog-Upload-Status"];
                    LVLog([NSString stringWithFormat:@"http code=%ld us=%@", (long)code, us ?: @"-"]);
                } @catch (__unused NSException *e) { }
                ((void (*)(id, SEL, id))o)(self, resp, response);
            });
            class_replaceMethod(f, resp, r, method_getTypeEncoding(m));
        }
    }
    if (tried) return;
    tried = YES;
    // Capture the app's Firebase ID token from outgoing Storage requests, so the direct
    // uploader can authenticate as the same user without any extra login.
    Class fetcherClass = NSClassFromString(@"GTMSessionFetcher");
    SEL startSel = NSSelectorFromString(@"startWithCompletionHandler:");
    Method startMethod = fetcherClass ? class_getInstanceMethod(fetcherClass, startSel) : NULL;
    if (startMethod) {
        IMP originalStart = method_getImplementation(startMethod);
        IMP startReplacement = imp_implementationWithBlock(^(id fetcher, id completion) {
            @try {
                id request = [fetcher valueForKey:@"request"];
                if ([request isKindOfClass:NSClassFromString(@"NSURLRequest")]) {
                    NSString *auth = [(NSURLRequest *)request valueForHTTPHeaderField:@"Authorization"];
                    if (auth.length > 7) {
                        LVStoreToken([auth substringFromIndex:7]);
                    }
                }
            } @catch (__unused NSException *e) { }
            ((void (*)(id, SEL, id))originalStart)(fetcher, startSel, completion);
        });
        class_replaceMethod(fetcherClass, startSel, startReplacement, method_getTypeEncoding(startMethod));
    }
    Class uploader = NSClassFromString(@"GTMSessionUploadFetcher");
    SEL selector = @selector(beginFetchWithCompletionHandler:);
    Method method = uploader ? class_getInstanceMethod(uploader, selector) : NULL;
    if (!method) return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id fetcher, LVFetchCompletion completion) {
        @try {
            NSInteger chunk = 0;
            int64_t length = -1;
            if ([fetcher respondsToSelector:@selector(chunkSize)])
                chunk = [[fetcher valueForKey:@"chunkSize"] integerValue];
            if ([fetcher respondsToSelector:NSSelectorFromString(@"fullUploadLength")])
                length = (int64_t)[[fetcher valueForKey:@"fullUploadLength"] longLongValue];
            NSString *url = @"?";
            @try { url = [[[fetcher valueForKey:@"request"] URL] absoluteString] ?: @"?"; }
            @catch (__unused NSException *e) { }
            LVLog([NSString stringWithFormat:@"up start chunk=%ld len=%lld %@",
                   (long)chunk, (long long)length, url]);
            // Never exceed 32 MiB: INT64_MAX broke the uploader (chunk=9223372036854775807).
            int64_t target = 0x2000000;
            if (length > 0 && length < target) target = length;
            if (chunk != target) {
                [fetcher setValue:@(target) forKey:@"chunkSize"];
                LVLog([NSString stringWithFormat:@"up chunk=%lld", (long long)target]);
            }
        } @catch (__unused NSException *e) { }
        ((void (*)(id, SEL, LVFetchCompletion))original)(fetcher, selector, completion);
    });
    class_replaceMethod(uploader, selector, replacement, method_getTypeEncoding(method));
}
// Remote Config feature gate override. Only the two named keys are affected. The object the
// original -configValueForKey: returned is NEVER replaced: a marker is attached to that same
// instance so its own getters can answer true without changing the class the app receives.
static Class LVRemoteConfigValueClass;
// Probe only: a dynamic -boolValue send reaches whichever implementation the receiver's class
// has (the replacement), which passes through to the real IMP while the marker is unset.
@protocol LVRemoteConfigValueReading <NSObject>
- (BOOL)boolValue;
@end
static char LVRemoteConfigMarkerKey;
static BOOL LVRemoteConfigWantedKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;
    // Mic + upload + sound. camera_roll_preview_enabled is left alone: forcing it
    // made the library fail with "Không thể tải các mục".
    return [key isEqualToString:@"internal_camera_roll_video_upload_enabled"] ||
           [key isEqualToString:@"camera_microphone_enabled"] ||
           [key isEqualToString:@"video_sound_enabled"] ||
           [key isEqualToString:@"sound_enabled"];
}
static BOOL LVRemoteConfigMarked(id value) {
    return value && objc_getAssociatedObject(value, &LVRemoteConfigMarkerKey) != nil;
}
// Force-true even when the value object is not FIRRemoteConfigValue (Swift wrapper).
static void LVRemoteConfigMarkAny(id value, NSString *key) {
    if (!value || LVRemoteConfigMarked(value)) return;
    @try {
        objc_setAssociatedObject(value, &LVRemoteConfigMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static BOOL logged;
        if (!logged) {
            logged = YES;
            LVLog([NSString stringWithFormat:@"rc mark class=%@ key=%@", NSStringFromClass([value class]), key]);
        }
    } @catch (__unused NSException *e) { }
}
static void LVRemoteConfigForceClass(id value);

// Replace a getter only on the class that implements it (owned methods), like LVInstallOne.
static void LVRemoteConfigInstallGetter(Class cls, SEL selector, BOOL ownedOnly) {
    Method method = NULL;
    if (ownedOnly) {
        if (!LVOwnsSelector(cls, selector, &method)) return;
    } else {
        method = class_getInstanceMethod(cls, selector);
        if (!method) return;
    }
    NSString *key = [NSString stringWithFormat:@"%p:%s", cls, sel_getName(selector)];
    if ([LVInstalled containsObject:key]) return;
    IMP original = method_getImplementation(method);
    IMP replacement = NULL;
    if (sel_isEqual(selector, @selector(boolValue))) {
        replacement = imp_implementationWithBlock(^BOOL(id value) {
            if (LVRemoteConfigMarked(value)) return YES;
            return ((BOOL (*)(id, SEL))original)(value, selector);
        });
    } else if (sel_isEqual(selector, @selector(stringValue))) {
        replacement = imp_implementationWithBlock(^NSString *(id value) {
            if (LVRemoteConfigMarked(value)) return @"1";
            return ((NSString *(*)(id, SEL))original)(value, selector);
        });
    } else if (sel_isEqual(selector, @selector(numberValue))) {
        replacement = imp_implementationWithBlock(^NSNumber *(id value) {
            if (LVRemoteConfigMarked(value)) return @1;
            return ((NSNumber *(*)(id, SEL))original)(value, selector);
        });
    }
    if (!replacement) return;
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    [LVInstalled addObject:key];
}
static void LVRemoteConfigForceClass(id value) {
    if (!value) return;
    Class cls = [value class];
    if (!cls || cls == LVRemoteConfigValueClass) return;
    LVRemoteConfigInstallGetter(cls, @selector(boolValue), NO);
    LVRemoteConfigInstallGetter(cls, @selector(stringValue), NO);
    LVRemoteConfigInstallGetter(cls, @selector(numberValue), NO);
}
static void LVRemoteConfigInstallConfigHook(Class cls) {
    SEL selectors[] = {@selector(configValueForKey:), @selector(configValueForKey:source:),
                       @selector(objectForKeyedSubscript:)};
    for (unsigned i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL selector = selectors[i];
        Method method = class_getInstanceMethod(cls, selector); // source: variant is optional
        if (!method) continue;
        NSString *key = [NSString stringWithFormat:@"%p:%s", cls, sel_getName(selector)];
        if ([LVInstalled containsObject:key]) continue;
        IMP original = method_getImplementation(method);
        IMP replacement;
        if (i == 0 || i == 2) {
            replacement = imp_implementationWithBlock(^id(id config, id name) {
                id value = ((id (*)(id, SEL, id))original)(config, selector, name);
                @try {
                    if (value && LVRemoteConfigWantedKey(name)) {
                        LVRemoteConfigForceClass(value);
                        LVRemoteConfigMarkAny(value, name);
                    }
                } @catch (__unused NSException *e) { }
                return value; // the SAME instance the original returned
            });
        } else {
            replacement = imp_implementationWithBlock(^id(id config, NSString *name, NSInteger source) {
                id value = ((id (*)(id, SEL, NSString *, NSInteger))original)(config, selector, name, source);
                @try {
                    if (value && LVRemoteConfigWantedKey(name)) {
                        LVRemoteConfigForceClass(value);
                        LVRemoteConfigMarkAny(value, name);
                    }
                } @catch (__unused NSException *e) { }
                return value;
            });
        }
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
        [LVInstalled addObject:key];
    }
}
static id LVForcedConfigValue(void) {
    Class valueClass = NSClassFromString(@"FIRRemoteConfigValue");
    if (!valueClass) return nil;
    SEL initSel = @selector(initWithData:source:);
    if (![valueClass instancesRespondToSelector:initSel]) return nil;
    NSData *one = [@"1" dataUsingEncoding:NSUTF8StringEncoding];
    id value = [valueClass alloc];
    // LocketFull6 passes source 0, not 1.
    return ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(value, initSel, one, 0);
}
static void LVInstallRemoteConfigOverrides(void) {
    static BOOL installed;
    if (installed) return;
    @try {
        Class rc = NSClassFromString(@"FIRRemoteConfig");
        Class valueClass = NSClassFromString(@"FIRRemoteConfigValue");
        if (!rc || !valueClass) {
            LVLog(@"rc class absent");
            return;
        }
        // Same mechanism as LocketFull6 on 2.69: replace the returned value object
        // with one built from @"1", instead of marking the server object.
        NSUInteger hooked = 0;
        // Only FIRRemoteConfig itself. Dictionary subscripts are unrelated and caused false hits.
        SEL selectors[] = { @selector(configValueForKey:), @selector(objectForKeyedSubscript:) };
        for (unsigned i = 0; i < 2; i++) {
            SEL selector = selectors[i];
            Method method = class_getInstanceMethod(rc, selector);
            if (!method) continue;
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^id(id config, id name) {
                if (LVRemoteConfigWantedKey(name)) {
                    LVLog([NSString stringWithFormat:@"rc force %@ recv=%@", name, NSStringFromClass([config class])]);
                    // Dictionary receivers (2.71.2 config snapshot) need a plain value.
                    if ([config isKindOfClass:NSDictionary.class]) return @YES;
                    id forced = LVForcedConfigValue();
                    if (forced) return forced;
                }
                return ((id (*)(id, SEL, id))original)(config, selector, name);
            });
            class_replaceMethod(rc, selector, replacement, method_getTypeEncoding(method));
            hooked++;
        }
        // Dictionary subscript hooking was removed: replacing methods on __NSDictionaryI
        // affects every dictionary in the process and crashed the app.
        installed = YES;
        LVLog([NSString stringWithFormat:@"rc hooked %lu", (unsigned long)hooked]);
    } @catch (__unused NSException *e) {
        LVLog(@"rc install exception");
    }
}
static void LVInstallCameraGates(void) {
    static BOOL done;
    if (done) return;
    Class recorder = NSClassFromString(@"Camera.Recorder") ?: NSClassFromString(@"_TtC6Camera8Recorder");
    Class camera = NSClassFromString(@"Camera.CameraViewController") ?: NSClassFromString(@"_TtC6Camera20CameraViewController");
    if (!recorder && !camera) {
        LVLog(@"camera classes absent");
        return;
    }
    done = YES;
    void (^force)(id) = ^(id obj) {
        if (!obj) return;
        @try {
            for (NSString *key in @[
                @"microphoneEnabled", @"_microphoneEnabled",
                @"microphoneButtonEnabled", @"_microphoneButtonEnabled",
                @"microphoneConfigured", @"_microphoneConfigured",
                @"cameraRollVideoUploadEnabled", @"_cameraRollVideoUploadEnabled",
                @"longerVideosEnabled", @"_longerVideosEnabled"]) {
                @try { [obj setValue:@YES forKey:key];
                    LVLog([NSString stringWithFormat:@"set %@ on %@", key, NSStringFromClass([obj class])]);
                } @catch (__unused NSException *e) { }
            }
        } @catch (NSException *e) {
            LVLog([NSString stringWithFormat:@"camera kvc %@ %@", NSStringFromClass([obj class]), e.reason]);
        }
    };
    if (recorder) {
        // Swift stored properties are often KVC as _name, not name. Try both on the recorder class
        // by swizzling a method that runs while an instance exists is not available here.
        // Force via associated observation is unsafe. Log ivars so the next patch writes the right offset.
        unsigned n = 0;
        Ivar *ivars = class_copyIvarList(recorder, &n);
        NSMutableString *names = [NSMutableString string];
        for (unsigned i = 0; i < n && i < 24; i++) {
            const char *nm = ivar_getName(ivars[i]);
            if (nm) [names appendFormat:@" %s", nm];
        }
        free(ivars);
        LVLog([NSString stringWithFormat:@"recorder ivars%@", names]);
    }
}
static void LVInstallMicButton(void) {
}
__attribute__((constructor)) static void LV17Load(void) {
    @autoreleasepool {
        // Only the authorized Locket main executable, never extensions or unrelated apps.
        NSString *executable = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"];
        if (![executable isEqualToString:@"Locket"]) return;
        LVEnabled = YES;
        LVLogQueue = dispatch_queue_create("local.locket.video17.log", DISPATCH_QUEUE_SERIAL);
        LVInstalled = [NSMutableSet set];
        LVInstallClasses();
        LVInstallUploaderChunkHook();
        LVInstallRemoteConfigOverrides();
        LVInstallCameraGates();
        LVInstallMicButton();
        dispatch_async(dispatch_get_main_queue(), ^{
            LVInstallClasses();
            LVInstallUploaderChunkHook();
            LVInstallRemoteConfigOverrides();
            LVInstallCameraGates();
        });
    }
}
