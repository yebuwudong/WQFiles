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

NS_ASSUME_NONNULL_END
