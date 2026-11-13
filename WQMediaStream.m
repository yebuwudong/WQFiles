//
//  WQMediaStream.m
//  WQ Files
//

#import "WQMediaStream.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

static NSString *const kWQMediaScheme = @"wqmedia";
static const NSUInteger kWQMediaChunk = 512 * 1024;
static char kWQMediaStreamKey;

@interface WQMediaStream ()
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic) unsigned long long size;
@property (nonatomic, copy) WQMediaReadRange read;
@property (nonatomic, copy) void (^onFailure)(NSString *reason);
@property (nonatomic, weak) AVPlayerItem *item;
@property (nonatomic) BOOL failed;
@end

@implementation WQMediaStream {
    dispatch_queue_t _readQueue;
}

+ (BOOL)opensAsMediaByDefault:(NSString *)name
{
    static NSSet<NSString *> *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[@"mp3", @"m4a", @"m4b", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac", @"alac",
                                     @"mp4", @"m4v", @"mov", @"3gp", @"3g2"]];
    });
    return [exts containsObject:name.pathExtension.lowercaseString];
}

+ (NSString *)contentTypeForFileName:(NSString *)name
{
    NSString *ext = name.pathExtension.lowercaseString;
    // Playlists reference other files; those can't be served from here.
    if (!ext.length || [ext isEqualToString:@"m3u8"]) return nil;
    UTType *type = [UTType typeWithFilenameExtension:ext];
    if (!type || !([type conformsToType:UTTypeAudiovisualContent])) return nil;
    return type.identifier;
}

+ (AVPlayerItem *)playerItemForName:(NSString *)name size:(unsigned long long)size
                               read:(WQMediaReadRange)read onFailure:(void (^)(NSString *))onFailure
{
    NSString *contentType = [self contentTypeForFileName:name];
    if (!contentType || size == 0) return nil;
    WQMediaStream *stream = [WQMediaStream new];
    stream.contentType = contentType;
    stream.size = size;
    stream.read = read;
    stream.onFailure = onFailure;
    // The extension stays on the URL: AVFoundation also looks at it.
    NSString *escaped = [name.lastPathComponent stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://media/%@", kWQMediaScheme, escaped ?: @"media"]];
    if (!url) return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset.resourceLoader setDelegate:stream queue:dispatch_queue_create("wq.media.loader", DISPATCH_QUEUE_SERIAL)];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    stream.item = item;
    // The resource loader holds its delegate weakly: the item keeps it.
    objc_setAssociatedObject(item, &kWQMediaStreamKey, stream, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [item addObserver:stream forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:&kWQMediaStreamKey];
    return item;
}

- (instancetype)init
{
    if ((self = [super init])) _readQueue = dispatch_queue_create("wq.media.read", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc
{
    @try { [_item removeObserver:self forKeyPath:@"status" context:&kWQMediaStreamKey]; } @catch (NSException *__unused e) {}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != &kWQMediaStreamKey) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    AVPlayerItem *item = object;
    if (item.status != AVPlayerItemStatusFailed) return;
    NSString *reason = item.error.localizedDescription ?: @"the player failed";
    NSError *underlying = item.error.userInfo[NSUnderlyingErrorKey];
    if (underlying) reason = [reason stringByAppendingFormat:@" (%@ %ld)", underlying.domain, (long)underlying.code];
    [self failOnce:reason];
}

// Runs onFailure once, on the main queue, whichever path notices first.
- (void)failOnce:(NSString *)reason
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.failed) return;
        self.failed = YES;
        if (self.onFailure) self.onFailure(reason);
    });
}

- (NSData *)dataForOffset:(unsigned long long)offset length:(NSUInteger)length error:(NSString **)error
{
    if (offset >= _size) return [NSData data];
    unsigned long long left = _size - offset;
    NSUInteger want = (NSUInteger)MIN((unsigned long long)length, left);
    return _read(offset, want, error);
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request
{
    if (![request.request.URL.scheme isEqualToString:kWQMediaScheme]) return NO;
    AVAssetResourceLoadingContentInformationRequest *info = request.contentInformationRequest;
    if (info) {
        info.contentType = _contentType;
        info.contentLength = (long long)_size;
        info.byteRangeAccessSupported = YES;
    }
    AVAssetResourceLoadingDataRequest *data = request.dataRequest;
    if (!data) { [request finishLoading]; return YES; }
    // Reads happen off the loader queue, in chunks, so a seek can cancel a
    // long request between chunks.
    dispatch_async(_readQueue, ^{
        long long start = data.currentOffset;
        long long end = data.requestsAllDataToEndOfResource ? (long long)self->_size
                                                            : data.requestedOffset + (long long)data.requestedLength;
        end = MIN(end, (long long)self->_size);
        long long offset = start;
        while (offset < end) {
            if (request.isCancelled || request.isFinished) return;
            NSUInteger length = (NSUInteger)MIN((long long)kWQMediaChunk, end - offset);
            NSString *error = nil;
            NSData *chunk = [self dataForOffset:(unsigned long long)offset length:length error:&error];
            if (!chunk.length) {
                if (request.isCancelled || request.isFinished) return;
                NSString *reason = error ?: @"The file could not be read";
                [request finishLoadingWithError:[NSError errorWithDomain:@"WQMediaStream" code:1
                    userInfo:@{NSLocalizedDescriptionKey: reason}]];
                // Don't wait for the player to give up (it may retry or
                // stall): a failed read means the stream can't be trusted.
                [self failOnce:reason];
                return;
            }
            [data respondWithData:chunk];
            offset += (long long)chunk.length;
        }
        if (!request.isCancelled && !request.isFinished) [request finishLoading];
    });
    return YES;
}

@end

@implementation WQMediaFileReader {
    int _fd;
    struct stat _origin;
}

static BOOL WQMediaSameGeneration(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
           a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec;
}

- (instancetype)initWithDescriptor:(int)fd
{
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { close(fd); return nil; }
    if ((self = [super init])) {
        _fd = fd;
        _origin = st;
        _size = (unsigned long long)st.st_size;
    } else {
        close(fd);
    }
    return self;
}

- (void)dealloc
{
    if (_fd >= 0) close(_fd);
}

- (NSData *)readOffset:(unsigned long long)offset length:(NSUInteger)length error:(NSString **)error
{
    if (offset > _size) { if (error) *error = @"read past the end of the file"; return nil; }
    NSUInteger want = (NSUInteger)MIN((unsigned long long)length, _size - offset);
    NSMutableData *data = [NSMutableData dataWithLength:want];
    NSUInteger got = 0;
    while (got < want) {
        ssize_t n = pread(_fd, (uint8_t *)data.mutableBytes + got, want - got, (off_t)(offset + got));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { if (error) *error = [NSString stringWithUTF8String:strerror(errno)]; return nil; }
        if (n == 0) break;
        got += (NSUInteger)n;
    }
    // After the read: a change before or during it shows up here.
    struct stat now;
    if (fstat(_fd, &now) != 0 || !WQMediaSameGeneration(&_origin, &now)) {
        if (error) *error = @"the file changed while it was playing";
        return nil;
    }
    if (got != want) { if (error) *error = @"the file is shorter than when it was opened"; return nil; }
    return data;
}

@end
