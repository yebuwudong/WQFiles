//
//  WQMediaStreamTests.m
//  Plays generated media through the streaming resource loader on macOS:
//  the item must become ready, report the right duration, and decode audio
//  from the custom URL; a failing reader must trigger the fallback once.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "../WQMediaStream.h"

static int failures;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

static BOOL WaitFor(BOOL (^done)(void), NSTimeInterval seconds)
{
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return done();
}

static NSString *Fixture(NSString *dir, NSString *name, NSArray<NSString *> *command)
{
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:command[0]];
    NSMutableArray *args = [[command subarrayWithRange:NSMakeRange(1, command.count - 1)] mutableCopy];
    for (NSUInteger i = 0; i < args.count; i++) if ([args[i] isEqualToString:@"OUT"]) args[i] = path;
    task.arguments = args;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return nil;
    [task waitUntilExit];
    return task.terminationStatus == 0 && [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}

static void TestPlays(NSString *path, double expectSeconds, BOOL video)
{
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    __block NSUInteger reads = 0, maxRead = 0;
    __block NSString *failure = nil;
    AVPlayerItem *item = [WQMediaStream playerItemForName:path.lastPathComponent size:bytes.length
        read:^NSData *(unsigned long long offset, NSUInteger length, NSString **error) {
            @synchronized (bytes) { reads++; maxRead = MAX(maxRead, length); }
            if (offset >= bytes.length) { if (error) *error = @"past end"; return nil; }
            return [bytes subdataWithRange:NSMakeRange((NSUInteger)offset, MIN(length, bytes.length - (NSUInteger)offset))];
        } onFailure:^(NSString *reason) { failure = reason; }];
    CHECK(item != nil);
    if (!item) return;
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.volume = 0;
    CHECK(WaitFor(^BOOL { return item.status != AVPlayerItemStatusUnknown; }, 15));
    CHECK(item.status == AVPlayerItemStatusReadyToPlay);
    if (item.status != AVPlayerItemStatusReadyToPlay) fprintf(stderr, "  %s: %s\n", path.lastPathComponent.UTF8String, item.error.description.UTF8String);
    double duration = CMTimeGetSeconds(item.duration);
    CHECK(fabs(duration - expectSeconds) < 0.5);
    CHECK(reads > 0 && maxRead <= 512 * 1024);
    CHECK(failure == nil);
    BOOL hasTrack = NO;
    for (AVPlayerItemTrack *t in item.tracks)
        if ([t.assetTrack.mediaType isEqualToString:video ? AVMediaTypeVideo : AVMediaTypeAudio]) hasTrack = YES;
    CHECK(hasTrack);
    // Seek to the middle: served by range requests, not from the start.
    __block BOOL seeked = NO;
    [player seekToTime:CMTimeMakeWithSeconds(expectSeconds / 2, 600) completionHandler:^(BOOL finished) { seeked = finished; }];
    CHECK(WaitFor(^BOOL { return seeked; }, 10));
    [player play];
    CHECK(WaitFor(^BOOL { return CMTimeGetSeconds(player.currentTime) > expectSeconds / 2 + 0.2; }, 10));
    [player pause];
    if (bytes.length > 4 * 1024 * 1024) CHECK(reads > 2);   // range requests, not one read
    printf("PASS: %s streams (%lu bytes, %lu reads, %.1f s)\n", path.lastPathComponent.UTF8String,
           (unsigned long)bytes.length, (unsigned long)reads, duration);
}

static void TestFailureFallsBack(NSString *path)
{
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    __block NSUInteger failures_ = 0;
    __block NSString *reason = nil;
    AVPlayerItem *item = [WQMediaStream playerItemForName:path.lastPathComponent size:bytes.length
        read:^NSData *(unsigned long long __unused offset, NSUInteger __unused length, NSString **error) {
            if (error) *error = @"Operation not permitted";
            return nil;
        } onFailure:^(NSString *why) { failures_++; reason = why; }];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    (void)player;
    CHECK(WaitFor(^BOOL { return failures_ > 0; }, 15));
    WaitFor(^BOOL { return NO; }, 0.5);
    CHECK(failures_ == 1);
    CHECK(reason.length > 0);
    printf("PASS: unreadable stream reports failure once (%s)\n", reason.UTF8String);
}

int main(void)
{
    @autoreleasepool {
        CHECK([[WQMediaStream contentTypeForFileName:@"a.mp4"] isEqualToString:@"public.mpeg-4"]);
        CHECK([WQMediaStream contentTypeForFileName:@"a.M4A"] != nil);
        CHECK([WQMediaStream contentTypeForFileName:@"a.mp3"] != nil);
        CHECK([WQMediaStream contentTypeForFileName:@"a.mov"] != nil);
        CHECK([WQMediaStream contentTypeForFileName:@"list.m3u8"] == nil);
        CHECK([WQMediaStream contentTypeForFileName:@"notes.txt"] == nil);
        CHECK([WQMediaStream contentTypeForFileName:@"noextension"] == nil);
        CHECK([WQMediaStream playerItemForName:@"a.mp4" size:0 read:^NSData *(unsigned long long o, NSUInteger l, NSString **e) {
            (void)o; (void)l; (void)e; return nil; } onFailure:^(NSString *r) { (void)r; }] == nil);

        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQMediaStreamTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        // ~4 s of speech, as AAC in m4a and as WAV.
        NSString *aiff = Fixture(dir, @"speech.aiff", @[@"/usr/bin/say", @"-o", @"OUT", @"one two three four five six seven eight nine ten"]);
        NSString *m4a = aiff ? Fixture(dir, @"speech.m4a", @[@"/usr/bin/afconvert", @"-f", @"m4af", @"-d", @"aac", aiff, @"OUT"]) : nil;
        NSString *wav = aiff ? Fixture(dir, @"speech.wav", @[@"/usr/bin/afconvert", @"-f", @"WAVE", @"-d", @"LEI16", aiff, @"OUT"]) : nil;
        if (!m4a || !wav) {
            puts("SKIP: say/afconvert unavailable; stream playback not exercised");
        } else {
            AVURLAsset *ref = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:m4a] options:nil];
            double seconds = CMTimeGetSeconds(ref.duration);
            TestPlays(m4a, seconds, NO);
            TestPlays(wav, CMTimeGetSeconds([AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:wav] options:nil].duration), NO);
            TestFailureFallsBack(m4a);
        }
        // A short H.264 movie, if ffmpeg is installed.
        NSString *ffmpeg = [NSFileManager.defaultManager isExecutableFileAtPath:@"/opt/homebrew/bin/ffmpeg"] ? @"/opt/homebrew/bin/ffmpeg"
            : [NSFileManager.defaultManager isExecutableFileAtPath:@"/usr/local/bin/ffmpeg"] ? @"/usr/local/bin/ffmpeg" : nil;
        NSString *mp4 = ffmpeg ? Fixture(dir, @"clip.mp4", @[ffmpeg, @"-y", @"-f", @"lavfi", @"-i", @"testsrc=duration=30:size=1280x720:rate=30",
                                                             @"-pix_fmt", @"yuv420p", @"-c:v", @"libx264", @"-b:v", @"3M", @"-x264-params", @"nal-hrd=cbr", @"-minrate", @"3M", @"-maxrate", @"3M", @"-bufsize", @"1M", @"OUT"]) : nil;
        if (mp4) TestPlays(mp4, 30.0, YES);
        else puts("SKIP: ffmpeg unavailable; video stream not exercised");
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (failures) { fprintf(stderr, "%d media stream check(s) failed\n", failures); return 1; }
        puts("All media stream tests passed.");
    }
    return 0;
}
