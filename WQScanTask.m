#import "WQScanTask.h"
#import "WQScanJournal.h"

NSString *const WQScanTaskChangedNotification = @"WQScanTaskChanged";
static NSMutableDictionary *gTasks;
static BOOL gTasksPaused;
@implementation WQScanTask {
    void (^_cancel)(void);
}
+ (instancetype)taskNamed:(NSString *)name
{
    NSAssert(NSThread.isMainThread, @"task state belongs to the main thread");
    if (!gTasks) {
        gTasks = [NSMutableDictionary new];
        [NSNotificationCenter.defaultCenter addObserverForName:@"WQScanJournalWriteFailed" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSString *key = note.object;
            for (WQScanTask *task in gTasks.allValues) {
                if ([key isEqual:[@"task:" stringByAppendingString:task.name]] ||
                    [key hasPrefix:[NSString stringWithFormat:@"measure:%@:", task.name]] ||
                    ([key hasPrefix:@"inodes:"] && task.running)) {
                    task->_persistenceFailed = YES;
                    [task notify];
                }
            }
        }];
    }
    WQScanTask *task = gTasks[name];
    if (task) return task;
    task = [WQScanTask new];
    task->_name = [name copy];
    NSDictionary *saved = WQScanJournalLoad([@"task:" stringByAppendingString:name]);
    task->_identifier = [saved[@"identifier"] isKindOfClass:NSString.class] ? saved[@"identifier"] : NSUUID.UUID.UUIDString;
    task->_result = [saved[@"result"] isKindOfClass:NSDictionary.class] ? saved[@"result"] : nil;
    task->_finishedAt = [saved[@"finishedAt"] isKindOfClass:NSDate.class] ? saved[@"finishedAt"] : nil;
    task->_userPaused = [saved[@"userPaused"] isEqual:@YES];
    task->_interrupted = [saved[@"unfinished"] isEqual:@YES] && !task->_userPaused;
    task->_status = [saved[@"status"] isKindOfClass:NSString.class] ? saved[@"status"] : @"";
    task->_paused = gTasksPaused;
    task->_fraction = -1;
    gTasks[name] = task;
    return task;
}
+ (void)setPaused:(BOOL)paused
{
    NSAssert(NSThread.isMainThread, @"task state belongs to the main thread");
    gTasksPaused = paused;
    for (WQScanTask *task in gTasks.allValues) { task->_paused = paused; [task notify]; }
}
- (void)save
{
    NSMutableDictionary *saved = [@{@"identifier": _identifier, @"unfinished": @(_running || _interrupted || _userPaused), @"userPaused": @(_userPaused), @"status": _status ?: @""} mutableCopy];
    if (_result) saved[@"result"] = _result;
    if (_finishedAt) saved[@"finishedAt"] = _finishedAt;
    if (!WQScanJournalSave([@"task:" stringByAppendingString:_name], saved)) {
        _persistenceFailed = YES;
        NSLog(@"[wqfiles] Cannot save scan task %@; in-memory results retained", _name);
    }
}
- (void)notify
{
    [NSNotificationCenter.defaultCenter postNotificationName:WQScanTaskChangedNotification object:self];
}
- (NSUInteger)beginFresh:(BOOL)fresh cancel:(void (^)(void))cancel
{
    NSAssert(NSThread.isMainThread, @"task state belongs to the main thread");
    if (_running && !fresh) return 0;
    if (_cancel) _cancel();
    if (fresh || (!_interrupted && !_userPaused)) _identifier = NSUUID.UUID.UUIDString;
    _generation++;
    _cancel = [cancel copy];
    _running = YES;
    _interrupted = NO;
    _userPaused = NO;
    _status = @"";
    _fraction = -1;
    [self save];
    [self notify];
    return _generation;
}
- (void)pause
{
    NSAssert(NSThread.isMainThread, @"task state belongs to the main thread");
    if (!_running) return;
    if (_cancel) _cancel();
    _cancel = nil;
    _generation++;
    _running = NO;
    _interrupted = NO;
    _userPaused = YES;
    _status = @"Scan paused";
    _fraction = -1;
    [self save];
    [self notify];
}
- (void)progress:(NSString *)status generation:(NSUInteger)generation
{
    [self progress:status fraction:-1 generation:generation];
}
- (void)progress:(NSString *)status fraction:(float)fraction generation:(NSUInteger)generation
{
    NSAssert(NSThread.isMainThread, @"task state belongs to the main thread");
    if (generation != _generation || !_running) return;
    _status = [status copy];
    _fraction = fraction;
    [self notify];
}
- (void)finish:(NSDictionary *)result generation:(NSUInteger)generation
{
    NSAssert(NSThread.isMainThread, @"task state belongs to the main thread");
    if (generation != _generation || !_running) return;
    BOOL failed = [result[@"complete"] isEqual:@NO];
    if (!failed || !_result) {
        _result = [result copy];
        _finishedAt = NSDate.date;
    }
    _running = NO;
    _cancel = nil;
    _persistenceFailed = NO;
    _status = failed && [result[@"note"] isKindOfClass:NSString.class] ? result[@"note"] : @"";
    [self save];
    [self notify];
}
@end
