//
//  WQMediaStreamTests.m
//  Plays generated media through the streaming resource loader on macOS:
//  the item must become ready, report the right duration, and decode audio
//  from the custom URL; a failing reader must trigger the fallback once.
//  WQMediaFileReader must fail closed when the file changes under its single
//  descriptor. Fixture helpers (say, afconvert, ffmpeg) run with a time
//  limit; a helper that times out is terminated and reported as an explicit
//  SKIP naming the phase, so the suite can't hang on them.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "../WQMediaStream.h"
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

static BOOL WaitFor(BOOL (^done)(void), NSTimeInterval seconds)
{
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return done();
}

typedef NS_ENUM(NSInteger, FixtureStatus) { FixtureOK, FixtureUnavailable, FixtureFailed, FixtureTimedOut };
static NSMutableArray<NSString *> *skips;

static void Phase(NSString *phase)
{
    printf("phase: %s\n", phase.UTF8String);
    fflush(stdout);
}

static NSTimeInterval HelperTimeout(NSTimeInterval fallback)
{
    const char *env = getenv("WQ_MEDIA_HELPER_TIMEOUT");
    double value = env ? atof(env) : 0;
    return value > 0 ? value : fallback;
}

// Runs one fixture helper with a time limit. On timeout the helper (and only
// it: we own its pid) gets SIGTERM, then SIGKILL after a grace period.
static FixtureStatus RunHelper(NSArray<NSString *> *command, NSTimeInterval limit, NSString *stderrPath, NSString **detail)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:command[0]];
    task.arguments = [command subarrayWithRange:NSMakeRange(1, command.count - 1)];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    [NSFileManager.defaultManager createFileAtPath:stderrPath contents:nil attributes:nil];
    NSFileHandle *err = [NSFileHandle fileHandleForWritingAtPath:stderrPath];
    task.standardError = err ?: NSFileHandle.fileHandleWithNullDevice;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        [err closeFile];
        if (detail) *detail = launchError.localizedDescription;
        return FixtureUnavailable;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:limit];
    while (task.isRunning && deadline.timeIntervalSinceNow > 0) usleep(20000);
    BOOL timedOut = task.isRunning;
    if (timedOut) {
        [task terminate];
        NSDate *grace = [NSDate dateWithTimeIntervalSinceNow:3];
        while (task.isRunning && grace.timeIntervalSinceNow > 0) usleep(20000);
        if (task.isRunning) kill(task.processIdentifier, SIGKILL);
    }
    [task waitUntilExit];   // returns at once: the helper has exited or been killed
    [err closeFile];
    NSString *log = [NSString stringWithContentsOfFile:stderrPath encoding:NSUTF8StringEncoding error:nil];
    if (log.length > 400) log = [log substringFromIndex:log.length - 400];
    if (timedOut) {
        if (detail) *detail = [NSString stringWithFormat:@"timed out after %.0f s; stderr: %@", limit, log.length ? log : @"(empty)"];
        return FixtureTimedOut;
    }
    if (task.terminationStatus != 0) {
        if (detail) *detail = [NSString stringWithFormat:@"exit %d; stderr: %@", task.terminationStatus, log.length ? log : @"(empty)"];
        return FixtureFailed;
    }
    return FixtureOK;
}

static NSString *Fixture(NSString *dir, NSString *name, NSArray<NSString *> *command, NSTimeInterval limit)
{
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSMutableArray *args = [command mutableCopy];
    for (NSUInteger i = 0; i < args.count; i++) if ([args[i] isEqualToString:@"OUT"]) args[i] = path;
    NSString *phase = [NSString stringWithFormat:@"fixture %@ (%@)", name, command[0].lastPathComponent];
    Phase(phase);
    NSString *detail = nil;
    FixtureStatus status = RunHelper(args, HelperTimeout(limit), [path stringByAppendingString:@".stderr"], &detail);
    if (status == FixtureOK && [NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    NSString *what = status == FixtureTimedOut ? @"TIMEOUT" : status == FixtureUnavailable ? @"unavailable" : @"failed";
    NSString *line = [NSString stringWithFormat:@"%@ %@: %@", phase, what, detail ?: @"no output file"];
    [skips addObject:line];
    printf("SKIP: %s\n", line.UTF8String);
    if (status == FixtureTimedOut) fprintf(stderr, "SKIP: %s\n", line.UTF8String);
    return nil;
}

static WQMediaFileReader *OpenReader(NSString *path)
{
    return [[WQMediaFileReader alloc] initWithDescriptor:open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)];
}

// A helper that never exits must be terminated within its limit.
static void TestHelperTimeout(NSString *dir)
{
    Phase(@"helper timeout self-test");
    NSDate *start = NSDate.date;
    NSString *detail = nil;
    FixtureStatus status = RunHelper(@[@"/bin/sleep", @"60"], 1, [dir stringByAppendingPathComponent:@"sleep.stderr"], &detail);
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    CHECK(status == FixtureTimedOut);
    CHECK(elapsed < 10);
    CHECK([detail containsString:@"timed out"]);
    printf("PASS: a hung fixture helper is terminated (%.1f s)\n", elapsed);
}

static void TestReader(NSString *dir)
{
    Phase(@"file reader");
    NSString *path = [dir stringByAppendingPathComponent:@"reader.bin"];
    NSMutableData *bytes = [NSMutableData dataWithLength:100000];
    for (NSUInteger i = 0; i < bytes.length; i++) ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)(i * 7);
    [bytes writeToFile:path atomically:NO];

    CHECK([[WQMediaFileReader alloc] initWithDescriptor:-1] == nil);
    CHECK([[WQMediaFileReader alloc] initWithDescriptor:open(dir.fileSystemRepresentation, O_RDONLY)] == nil);

    // Ranges come from the one descriptor and are clamped to the size.
    WQMediaFileReader *reader = OpenReader(path);
    CHECK(reader.size == bytes.length);
    NSString *error = nil;
    CHECK([[reader readOffset:1000 length:5000 error:&error] isEqualToData:[bytes subdataWithRange:NSMakeRange(1000, 5000)]]);
    CHECK([[reader readOffset:99000 length:5000 error:&error] isEqualToData:[bytes subdataWithRange:NSMakeRange(99000, 1000)]]);
    CHECK([reader readOffset:200000 length:10 error:&error] == nil && error.length);

    // Replacing the path: the descriptor keeps reading the original bytes.
    NSString *other = [dir stringByAppendingPathComponent:@"reader.new"];
    [[NSData dataWithBytes:"replacement" length:11] writeToFile:other atomically:NO];
    CHECK(rename(other.fileSystemRepresentation, path.fileSystemRepresentation) == 0);
    error = nil;
    CHECK([[reader readOffset:0 length:4096 error:&error] isEqualToData:[bytes subdataWithRange:NSMakeRange(0, 4096)]]);
    CHECK(error == nil);

    // Truncation under the descriptor fails closed.
    [bytes writeToFile:path atomically:NO];
    reader = OpenReader(path);
    CHECK([reader readOffset:0 length:10 error:nil].length == 10);
    CHECK(truncate(path.fileSystemRepresentation, 50000) == 0);
    error = nil;
    CHECK([reader readOffset:0 length:10 error:&error] == nil);
    CHECK([error containsString:@"changed"]);

    // A same-size rewrite in place fails closed too.
    [bytes writeToFile:path atomically:NO];
    reader = OpenReader(path);
    CHECK([reader readOffset:0 length:10 error:nil].length == 10);
    usleep(20000);   // a distinct modification time
    int fd = open(path.fileSystemRepresentation, O_WRONLY);
    CHECK(fd >= 0 && pwrite(fd, "XXXX", 4, 500) == 4);
    if (fd >= 0) close(fd);
    error = nil;
    CHECK([reader readOffset:400 length:200 error:&error] == nil);
    CHECK(error.length > 0);
    printf("PASS: file reader reads one generation and fails closed on change\n");
}

// The stream reports a changed file once, so the player falls back to a copy.
static void TestChangedFileFallsBack(NSString *source, NSString *dir)
{
    Phase(@"changed file fallback");
    NSString *path = [dir stringByAppendingPathComponent:[@"changing." stringByAppendingString:source.pathExtension]];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    [NSFileManager.defaultManager copyItemAtPath:source toPath:path error:nil];
    WQMediaFileReader *reader = OpenReader(path);
    CHECK(reader != nil);
    if (!reader) return;
    __block NSUInteger calls = 0;
    __block NSString *reason = nil;
    AVPlayerItem *item = [WQMediaStream playerItemForName:path.lastPathComponent size:reader.size
        read:^NSData *(unsigned long long offset, NSUInteger length, NSString **error) {
            return [reader readOffset:offset length:length error:error];
        } onFailure:^(NSString *why) { calls++; reason = why; }];
    CHECK(truncate(path.fileSystemRepresentation, (off_t)(reader.size / 2)) == 0);
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.volume = 0;
    CHECK(WaitFor(^BOOL { return calls > 0; }, 15));
    WaitFor(^BOOL { return NO; }, 0.5);
    CHECK(calls == 1);
    CHECK([reason containsString:@"changed"]);
    printf("PASS: a file changed under the stream falls back once (%s)\n", reason.UTF8String);
}

static void TestPlays(NSString *path, double expectSeconds, BOOL video)
{
    Phase([@"stream " stringByAppendingString:path.lastPathComponent]);
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    WQMediaFileReader *reader = OpenReader(path);
    CHECK(reader != nil && reader.size == bytes.length);
    __block NSUInteger reads = 0, maxRead = 0;
    __block NSString *failure = nil;
    AVPlayerItem *item = [WQMediaStream playerItemForName:path.lastPathComponent size:bytes.length
        read:^NSData *(unsigned long long offset, NSUInteger length, NSString **error) {
            @synchronized (bytes) { reads++; maxRead = MAX(maxRead, length); }
            NSData *chunk = [reader readOffset:offset length:length error:error];
            if (chunk && ![chunk isEqualToData:[bytes subdataWithRange:NSMakeRange((NSUInteger)offset, chunk.length)]]) {
                if (error) *error = @"reader returned wrong bytes";
                return nil;
            }
            return chunk;
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
    Phase(@"unreadable stream");
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
        // Local HLS playlists open as text, not in the player.
        CHECK(![WQMediaStream opensAsMediaByDefault:@"list.m3u8"]);
        CHECK(![WQMediaStream opensAsMediaByDefault:@"LIST.M3U8"]);
        CHECK([WQMediaStream opensAsMediaByDefault:@"clip.MP4"]);
        CHECK([WQMediaStream opensAsMediaByDefault:@"song.m4a"]);
        CHECK(![WQMediaStream opensAsMediaByDefault:@"notes.txt"]);
        skips = [NSMutableArray new];
        CHECK([WQMediaStream contentTypeForFileName:@"notes.txt"] == nil);
        CHECK([WQMediaStream contentTypeForFileName:@"noextension"] == nil);
        CHECK([WQMediaStream playerItemForName:@"a.mp4" size:0 read:^NSData *(unsigned long long o, NSUInteger l, NSString **e) {
            (void)o; (void)l; (void)e; return nil; } onFailure:^(NSString *r) { (void)r; }] == nil);

        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQMediaStreamTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        TestHelperTimeout(dir);
        TestReader(dir);
        // ~4 s of speech, as AAC in m4a and as WAV.
        NSString *aiff = Fixture(dir, @"speech.aiff", @[@"/usr/bin/say", @"-o", @"OUT", @"one two three four five six seven eight nine ten"], 60);
        NSString *m4a = aiff ? Fixture(dir, @"speech.m4a", @[@"/usr/bin/afconvert", @"-f", @"m4af", @"-d", @"aac", aiff, @"OUT"], 60) : nil;
        NSString *wav = aiff ? Fixture(dir, @"speech.wav", @[@"/usr/bin/afconvert", @"-f", @"WAVE", @"-d", @"LEI16", aiff, @"OUT"], 60) : nil;
        if (!m4a || !wav) {
            puts("SKIP: say/afconvert unavailable; stream playback not exercised");
        } else {
            AVURLAsset *ref = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:m4a] options:nil];
            double seconds = CMTimeGetSeconds(ref.duration);
            TestPlays(m4a, seconds, NO);
            TestPlays(wav, CMTimeGetSeconds([AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:wav] options:nil].duration), NO);
            TestFailureFallsBack(m4a);
            TestChangedFileFallsBack(m4a, dir);
        }
        // A short H.264 movie, if ffmpeg is installed.
        NSString *ffmpeg = [NSFileManager.defaultManager isExecutableFileAtPath:@"/opt/homebrew/bin/ffmpeg"] ? @"/opt/homebrew/bin/ffmpeg"
            : [NSFileManager.defaultManager isExecutableFileAtPath:@"/usr/local/bin/ffmpeg"] ? @"/usr/local/bin/ffmpeg" : nil;
        NSString *mp4 = ffmpeg ? Fixture(dir, @"clip.mp4", @[ffmpeg, @"-y", @"-f", @"lavfi", @"-i", @"testsrc=duration=30:size=1280x720:rate=30",
                                                             @"-pix_fmt", @"yuv420p", @"-c:v", @"libx264", @"-b:v", @"3M", @"-x264-params", @"nal-hrd=cbr", @"-minrate", @"3M", @"-maxrate", @"3M", @"-bufsize", @"1M", @"OUT"], 180) : nil;
        if (mp4) TestPlays(mp4, 30.0, YES);
        else puts("SKIP: ffmpeg unavailable; video stream not exercised");
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (failures) { fprintf(stderr, "%d media stream check(s) failed\n", failures); return 1; }
        if (skips.count) printf("All media stream tests passed; %lu fixture(s) skipped: %s\n", (unsigned long)skips.count,
                                [skips componentsJoinedByString:@" | "].UTF8String);
        else puts("All media stream tests passed.");
    }
    return 0;
}
