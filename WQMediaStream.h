//
//  WQMediaStream.h
//  WQ Files
//
//  Plays media from other apps' folders without copying them first. The
//  player gets a custom URL; AVFoundation asks this object for byte ranges,
//  which WQ Files reads itself (the media process has no access to those
//  folders). If the item fails, onFailure runs once, so the caller can fall
//  back to copying the file.
//

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSData *_Nullable (^WQMediaReadRange)(unsigned long long offset, NSUInteger length, NSString *_Nullable *_Nullable error);

@interface WQMediaStream : NSObject <AVAssetResourceLoaderDelegate>

// Whether a file opens in the player automatically (by extension; the first
// bytes of MP4/MOV look like HEIC images). Local HLS playlists (.m3u8) don't:
// their segments and keys can't be resolved, so they open as text.
+ (BOOL)opensAsMediaByDefault:(NSString *)name;

// The type identifier the player is told for a file name ("public.mpeg-4"),
// or nil when the extension isn't one that streams this way.
+ (nullable NSString *)contentTypeForFileName:(NSString *)name;

// A player item that reads `size` bytes through `read`. The item keeps the
// stream alive. onFailure (main queue) gets the reason once if the item fails.
+ (nullable AVPlayerItem *)playerItemForName:(NSString *)name size:(unsigned long long)size
                                        read:(WQMediaReadRange)read
                                   onFailure:(void (^)(NSString *reason))onFailure;

// For tests: answers one data request range synchronously.
- (nullable NSData *)dataForOffset:(unsigned long long)offset length:(NSUInteger)length error:(NSString *_Nullable *_Nullable)error;

@end

// Reads one file through a single read-only descriptor, opened once by the
// caller (no-follow, via the access helpers), with pread for every range.
// Each read revalidates the descriptor's identity, size and modification time
// against the values at creation and fails on any difference (truncation,
// growth, in-place rewrite), so a stream never mixes file generations; the
// caller then falls back to a stable copy. Replacing the path is harmless:
// the descriptor keeps reading the file it opened.
@interface WQMediaFileReader : NSObject
// Takes ownership of fd (closed on dealloc, or at once when this returns nil).
// Nil when fd is not an open regular file.
- (nullable instancetype)initWithDescriptor:(int)fd;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) unsigned long long size;
// Exactly min(length, size - offset) bytes, or nil with a reason.
- (nullable NSData *)readOffset:(unsigned long long)offset length:(NSUInteger)length error:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
