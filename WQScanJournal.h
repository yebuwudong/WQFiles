// Durable, app-private scan state. Never stores sandbox tokens or file contents.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

NS_ASSUME_NONNULL_BEGIN
static inline NSString *WQScanJournalDirectory(void)
{
#ifdef WQ_ACCESS_TESTING
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"scan-journal"];
#else
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"ScanTasks"];
#endif
}
static inline NSString *WQScanJournalPath(NSString *key)
{
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *name = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [name appendFormat:@"%02x", digest[i]];
    return [WQScanJournalDirectory() stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
}
static inline NSDictionary *_Nullable WQScanJournalLoad(NSString *key)
{
    NSDictionary *envelope = [NSDictionary dictionaryWithContentsOfFile:WQScanJournalPath(key)];
    if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"version"] isEqual:@1] ||
        ![envelope[@"key"] isEqual:key] || ![envelope[@"value"] isKindOfClass:NSDictionary.class]) return nil;
    return envelope[@"value"];
}
static inline BOOL WQScanJournalFailed(NSString *key)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"WQScanJournalWriteFailed" object:key];
    });
    return NO;
}
static inline BOOL WQScanJournalSave(NSString *key, NSDictionary *value)
{
    // Directory setup once per process, not on every save.
    static BOOL ready;
    NSString *directory = WQScanJournalDirectory();
    if (!ready) {
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                     attributes:@{NSFilePosixPermissions: @0700} error:nil]) return WQScanJournalFailed(key);
        NSURL *url = [NSURL fileURLWithPath:directory];
        [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        ready = YES;
    }
    NSDictionary *envelope = @{@"version": @1, @"key": key, @"value": value};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:envelope format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data && [data writeToFile:WQScanJournalPath(key) options:NSDataWritingAtomic error:nil]) return YES;
    return WQScanJournalFailed(key);
}
static inline void WQScanJournalRemove(NSString *key)
{
    [NSFileManager.defaultManager removeItemAtPath:WQScanJournalPath(key) error:nil];
}
// Journals nobody resumed (an app uninstalled mid-measure, a scan never
// reopened): removed at launch once older than `age` seconds.
static inline void WQScanJournalPrune(NSTimeInterval age)
{
    NSString *directory = WQScanJournalDirectory();
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] ?: @[]) {
        if (![name hasSuffix:@".plist"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
        if (modified && -modified.timeIntervalSinceNow > age) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
}
static inline NSDictionary *WQScanEncode(id object, NSArray<NSString *> *keys)
{
    NSMutableDictionary *row = [NSMutableDictionary new];
    for (NSString *key in keys) { id value = [object valueForKey:key]; if (value) row[key] = value; }
    return row;
}
static inline void WQScanDecode(id object, NSDictionary *row, NSArray<NSString *> *strings, NSArray<NSString *> *numbers)
{
    for (NSString *key in strings) if ([row[key] isKindOfClass:NSString.class]) [object setValue:row[key] forKey:key];
    for (NSString *key in numbers) if ([row[key] isKindOfClass:NSNumber.class]) [object setValue:row[key] forKey:key];
}
NS_ASSUME_NONNULL_END
