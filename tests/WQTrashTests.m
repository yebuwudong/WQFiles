// Recently Deleted on the host: deleted files are listed (newest backup per
// path), overwritten files that still exist are not, and restoring recreates
// missing folders without replacing anything.
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#import "../WQTrash.m"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write fixture"); }
static BOOL has(NSString *path, NSString *text) { return [[NSData dataWithContentsOfFile:path] isEqual:bytes(text)]; }

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQTrashTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        check([fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil], @"fixture folder");
        wq_test_backup_root = [base stringByAppendingPathComponent:@"Backups"];
        wq_test_app_backup_root = [base stringByAppendingPathComponent:@"AppBackups"];
        NSString *data = [base stringByAppendingPathComponent:@"data"];
        NSString *folder = [data stringByAppendingPathComponent:@"Saves/Slot1"];
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *kept = [data stringByAppendingPathComponent:@"settings.plist"];
        NSString *gone = [data stringByAppendingPathComponent:@"notes.txt"];
        NSString *nested = [folder stringByAppendingPathComponent:@"game.sav"];
        put(kept, @"v1"); put(gone, @"first"); put(nested, @"progress");
        NSString *error = nil;

        check(wq_recently_deleted().count == 0, @"nothing deleted yet");
        check(wq_write(kept, bytes(@"v2"), &error), @"overwrite keeps a backup");
        check(wq_write(gone, bytes(@"second"), &error), @"overwrite before delete");
        usleep(1100000);   // a later stamp second for the delete
        check(wq_delete(gone, &error), @"delete a file");
        check(wq_delete(nested, &error), @"delete a file in a folder");
        check(rmdir(folder.fileSystemRepresentation) == 0 && rmdir(folder.stringByDeletingLastPathComponent.fileSystemRepresentation) == 0,
              @"remove the now empty folders");

        NSArray<WQDeletedItem *> *items = wq_recently_deleted();
        NSMutableSet *originals = [NSMutableSet new];
        for (WQDeletedItem *item in items) [originals addObject:item.originalPath];
        check(items.count == 2 && [originals isEqualToSet:[NSSet setWithObjects:gone, nested, nil]],
              @"lists exactly the deleted files, not the overwritten one that still exists");
        WQDeletedItem *notes = nil, *save = nil;
        for (WQDeletedItem *item in items) {
            if ([item.originalPath isEqualToString:gone]) notes = item;
            if ([item.originalPath isEqualToString:nested]) save = item;
        }
        check(has(notes.backupPath, @"second"), @"newest backup per path (the contents when deleted)");
        check(notes.date != nil && notes.size == 6, @"date and size known");

        check(wq_restore_deleted(save, &error) && has(nested, @"progress"), @"restore recreates the missing folders");
        check(wq_recently_deleted().count == 1, @"restored file leaves the list");
        put(gone, @"new file meanwhile");
        check(!wq_restore_deleted(notes, &error) && has(gone, @"new file meanwhile"), @"restore never replaces an existing file");
        check(wq_recently_deleted().count == 0, @"a path that exists again isn't listed");

        check(wq_backup_stamp_date(@"20261111-175959-512-1") != nil && wq_backup_stamp_date(@"notastamp") == nil, @"stamp dates");
        [fm removeItemAtPath:base error:nil];
        puts("All Recently Deleted tests passed.");
    }
    return 0;
}
