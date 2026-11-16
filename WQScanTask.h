#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Main-thread task state. Screens observe it; workers publish generation-bound
// progress/results. A fresh scan never destroys the last completed result.
extern NSString *const WQScanTaskChangedNotification;
@interface WQScanTask : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly, nullable) NSDictionary *result;
@property (nonatomic, readonly, nullable) NSDate *finishedAt;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL paused;
+ (void)setPaused:(BOOL)paused;
@property (nonatomic, readonly) BOOL interrupted;
@property (nonatomic, readonly) BOOL userPaused;
@property (nonatomic, readonly) BOOL persistenceFailed;
- (void)pause;
@property (nonatomic, readonly) NSString *status;
// Share done of the current step (0…1) for a progress bar; negative when unknown.
@property (nonatomic, readonly) float fraction;
@property (nonatomic, readonly) NSUInteger generation;
+ (instancetype)taskNamed:(NSString *)name;
// Returns zero when already running. Fresh cancels/replaces the old worker;
// a resumed task keeps its identifier (and measurement checkpoints).
- (NSUInteger)beginFresh:(BOOL)fresh cancel:(void (^)(void))cancel;
- (void)progress:(NSString *)status generation:(NSUInteger)generation;
- (void)progress:(NSString *)status fraction:(float)fraction generation:(NSUInteger)generation;
- (void)finish:(NSDictionary *)result generation:(NSUInteger)generation;
@end
NS_ASSUME_NONNULL_END
