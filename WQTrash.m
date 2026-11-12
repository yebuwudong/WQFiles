//
//  WQTrash.m
//  WQ Files
//

#import "WQTrash.h"
#import "WQAccess.h"
#import "WQLocalization.h"
#include <sys/stat.h>

@implementation WQDeletedItem
@end

NSDate *wq_backup_stamp_date(NSString *stamp)
{
    if (stamp.length < 15) return nil;
    static NSDateFormatter *format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        format = [NSDateFormatter new];
        format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        format.dateFormat = @"yyyyMMdd-HHmmss";
    });
    @synchronized (format) { return [format dateFromString:[stamp substringToIndex:15]]; }
}

typedef NS_ENUM(NSInteger, WQPathPresence) { WQPathPresent, WQPathMissing, WQPathUnknown };

static WQPathPresence wq_presence_once(NSString *path)
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0) return WQPathPresent;
    return (errno == ENOENT || errno == ENOTDIR) ? WQPathMissing : WQPathUnknown;
}

// Whether the original is still there. Other apps' folders may refuse a plain
// lstat; then a token for the parent settles it. Unknown counts as present,
// so nothing is listed as deleted unless it really is.
static BOOL wq_original_missing(NSString *path, NSMutableDictionary<NSString *, NSNumber *> *grantedParents)
{
    WQPathPresence p = wq_presence_once(path);
    if (p != WQPathUnknown) return p == WQPathMissing;
    NSString *parent = path.stringByDeletingLastPathComponent;
    NSNumber *granted = grantedParents[parent];
    if (!granted) {
        granted = @(wq_grant(parent));
        grantedParents[parent] = granted;
    }
    if (!granted.boolValue) {
        // No token: the parent itself may be gone (a deleted folder).
        return wq_presence_once(parent) == WQPathMissing;
    }
    return wq_presence_once(path) == WQPathMissing;
}

NSArray<WQDeletedItem *> *wq_recently_deleted(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = wq_backup_root();
    NSArray<NSString *> *units = [[fm contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableDictionary<NSString *, WQDeletedItem *> *newest = [NSMutableDictionary new];
    for (NSString *unitName in units) {
        if ([unitName hasPrefix:@"."]) continue;
        NSDate *date = wq_backup_stamp_date(unitName);
        if (!date) continue;
        NSString *unit = [root stringByAppendingPathComponent:unitName];
        NSMutableArray<NSString *> *files = [NSMutableArray new];
        NSDirectoryEnumerator *walk = [fm enumeratorAtURL:[NSURL fileURLWithPath:unit]
                               includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey] options:0 errorHandler:nil];
        for (NSURL *url in walk) {
            NSNumber *regular = nil, *link = nil;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
            if (regular.boolValue && !link.boolValue) [files addObject:url.path];
        }
        for (NSString *file in files) {
            NSString *original = wq_backup_original_path(file);
            if (!original) continue;
            WQDeletedItem *known = newest[original];
            // Units are visited oldest first, so a later one replaces it.
            WQDeletedItem *item = known ?: [WQDeletedItem new];
            item.backupPath = file;
            item.originalPath = original;
            item.unitPath = unit;
            item.unitFileCount = files.count;
            item.date = date;
            struct stat st;
            item.size = lstat(file.fileSystemRepresentation, &st) == 0 ? (unsigned long long)st.st_size : 0;
            newest[original] = item;
        }
    }
    NSMutableDictionary *grantedParents = [NSMutableDictionary new];
    NSMutableArray<WQDeletedItem *> *deleted = [NSMutableArray new];
    for (WQDeletedItem *item in newest.allValues)
        if (wq_original_missing(item.originalPath, grantedParents)) [deleted addObject:item];
    [deleted sortUsingComparator:^NSComparisonResult(WQDeletedItem *a, WQDeletedItem *b) {
        NSComparisonResult byDate = [b.date compare:a.date];
        return byDate != NSOrderedSame ? byDate : [a.originalPath compare:b.originalPath];
    }];
    return deleted;
}

BOOL wq_restore_deleted(WQDeletedItem *item, NSString **errorText)
{
    // Recreate missing parent folders, outermost first.
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    NSString *dir = item.originalPath.stringByDeletingLastPathComponent;
    while (dir.length > 1) {
        struct stat st;
        if (wq_stat(dir, &st)) {
            if (!S_ISDIR(st.st_mode)) {
                if (errorText) *errorText = WQLocalizedFormat(@"%@ is not a folder anymore.", dir);
                return NO;
            }
            break;
        }
        [missing insertObject:dir atIndex:0];
        dir = dir.stringByDeletingLastPathComponent;
    }
    for (NSString *folder in missing)
        if (!wq_create_dir(folder, errorText)) return NO;
    BOOL ok = wq_create_file_from(item.originalPath, item.backupPath, errorText);
    wq_log(@"recently deleted: restore %@ from %@: %@", item.originalPath, item.unitPath.lastPathComponent,
           ok ? @"OK" : (errorText && *errorText ? *errorText : @"failed"));
    return ok;
}
