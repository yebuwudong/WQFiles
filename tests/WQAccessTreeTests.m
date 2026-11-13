#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }
static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static BOOL has(NSString *path, NSString *text) { return [[NSData dataWithContentsOfFile:path] isEqual:bytes(text)]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write temp sentinel"); }
static void mkdirs(NSString *path) { check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create temp tree"); }

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQAccessTreeTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            NSString *foreign = [base stringByAppendingPathComponent:@"foreign/Caches"];
            mkdirs(foreign);
            NSString *sentinel = [foreign stringByAppendingPathComponent:@"sentinel"];
            put(sentinel, @"outside");
            NSString *container = [base stringByAppendingPathComponent:@"container"];
            mkdirs(container);
            NSString *library = [container stringByAppendingPathComponent:@"Library"];
            check(symlink(foreign.stringByDeletingLastPathComponent.fileSystemRepresentation, library.fileSystemRepresentation) == 0, @"create symlinked Library");
            unsigned long long freed = 0;
            check(!wq_purge_contents([library stringByAppendingPathComponent:@"Caches"], &freed) && has(sentinel, @"outside") && freed == 0, @"symlinked purge ancestry fails closed");
            check(!wq_purge_contents([library stringByAppendingPathComponent:@"missing"], &freed), @"unsafe ancestry not treated as missing success");
            check(!wq_purge_contents(library, &freed) && has(sentinel, @"outside"), @"symlinked final purge target refused");
            check(unlink(library.fileSystemRepresentation) == 0, @"remove fixture symlink");
            NSString *cache = [library stringByAppendingPathComponent:@"Caches"];
            mkdirs([cache stringByAppendingPathComponent:@"nested"]);
            put([cache stringByAppendingPathComponent:@"nested/file"], @"12345");
            check(symlink(foreign.fileSystemRepresentation, [cache stringByAppendingPathComponent:@"external-link"].fileSystemRepresentation) == 0, @"create child link to foreign tree");
            check(wq_purge_contents(cache, &freed) && [fm contentsOfDirectoryAtPath:cache error:nil].count == 0 && freed >= 5, @"safe purge removes nested children and leaves root");
            check(has(sentinel, @"outside"), @"purge unlinks child symlink without following it");
            NSString *alias = [cache stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
            put([cache stringByAppendingPathComponent:@"alias-file"], @"alias");
            check(wq_purge_contents(alias, &freed), @"canonical var alias accepted");
            check(wq_purge_contents([cache stringByAppendingPathComponent:@"missing"], &freed), @"safe missing folder remains success");
            put([cache stringByAppendingPathComponent:@"retained"], @"keep");
            NSString *moved = [library stringByAppendingPathComponent:@"MovedCaches"];
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"purgeChild"] && [path isEqual:cache]) {
                    check(rename(cache.fileSystemRepresentation, moved.fileSystemRepresentation) == 0, @"swap purge root after listing");
                    check(symlink(foreign.fileSystemRepresentation, cache.fileSystemRepresentation) == 0, @"install foreign purge alias");
                }
            };
            check(!wq_purge_contents(cache, &freed) && has([moved stringByAppendingPathComponent:@"retained"], @"keep") && has(sentinel, @"outside"), @"changed purge ancestry rejected before deleting listed child");
            wq_test_tree_hook = nil;

            NSString *src = [base stringByAppendingPathComponent:@"rename-source"];
            NSString *dst = [base stringByAppendingPathComponent:@"rename-destination"];
            NSString *error = nil;
            put(src, @"source");
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"renameReady"]) put(path, @"competitor");
            };
            check(!wq_rename(src, dst.lastPathComponent, &error) && has(dst, @"competitor") && has(src, @"source"), @"concurrent destination creator cannot be overwritten");
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:dst error:nil];
            check(wq_rename(src, dst.lastPathComponent, &error) && has(dst, @"source"), @"no-replace rename succeeds for absent destination");
            put(src, @"source");
            NSString *dirDest = [base stringByAppendingPathComponent:@"directory-destination"];
            mkdirs(dirDest);
            check(!wq_rename(src, dirDest.lastPathComponent, &error), @"rename preserves existing directory destination");
            NSString *linkDest = [base stringByAppendingPathComponent:@"link-destination"];
            check(symlink(sentinel.fileSystemRepresentation, linkDest.fileSystemRepresentation) == 0, @"create rename symlink destination");
            check(!wq_rename(src, linkDest.lastPathComponent, &error) && has(sentinel, @"outside"), @"rename preserves existing symlink destination");
            check(!wq_rename(src, @"..", &error) && !wq_rename(src, @".", &error), @"rename rejects special names");
            NSString *cancelDir = [base stringByAppendingPathComponent:@"cancel-cache"];
            mkdirs(cancelDir);
            NSString *cancelSentinel = [cancelDir stringByAppendingPathComponent:@"sentinel"];
            put(cancelSentinel, @"keep");
            WQScanCancellation *cancellation = [WQScanCancellation new];
            [cancellation cancel];
            freed = 0;
            check(!wq_purge_contents_cancellable(cancelDir, &freed, cancellation) && has(cancelSentinel, @"keep"),
                  @"cancelled purge leaves the tree intact");
            for (NSUInteger i = 0; i < 32; i++) {
                NSString *raceSrc = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"src-%lu", (unsigned long)i]];
                NSString *raceDst = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"dst-%lu", (unsigned long)i]];
                put(raceSrc, @"source");
                dispatch_group_t group = dispatch_group_create();
                __block BOOL created = NO;
                dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    int fd = open(raceDst.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
                    if (fd >= 0) { created = YES; check(WQWriteBytes(fd, bytes(@"competitor")), @"write racing creator"); close(fd); }
                });
                BOOL renamed = wq_rename(raceSrc, raceDst.lastPathComponent, &error);
                dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
                check(created ? (!renamed && has(raceDst, @"competitor")) : (renamed && has(raceDst, @"source")), @"race preserves whichever destination wins exclusion");
            }

            // CR-02: recursive delete is pinned to the selected tree. The
            // progress callback swaps the root after the first child; the
            // walk must stop instead of deleting the replacement.
            wq_test_backup_root = [base stringByAppendingPathComponent:@"Backups"];
            wq_test_app_backup_root = [base stringByAppendingPathComponent:@"AppBackups"];
            NSString *treeRoot = [base stringByAppendingPathComponent:@"tree-root"];
            NSString *treeAside = [base stringByAppendingPathComponent:@"tree-root-original"];
            mkdirs(treeRoot);
            put([treeRoot stringByAppendingPathComponent:@"f1"], @"original1");
            put([treeRoot stringByAppendingPathComponent:@"f2"], @"original2");
            __block BOOL swapped = NO;
            NSUInteger removed = 0;
            NSString *unitPath = nil;
            BOOL treeOK = wq_delete_tree(treeRoot, nil, ^(NSUInteger n) {
                if (n != 1 || swapped) return;
                swapped = YES;
                check(rename(treeRoot.fileSystemRepresentation, treeAside.fileSystemRepresentation) == 0, @"move selected root aside mid-delete");
                mkdirs(treeRoot);
                put([treeRoot stringByAppendingPathComponent:@"f1"], @"replacement1");
                put([treeRoot stringByAppendingPathComponent:@"f2"], @"replacement2");
                check(symlink(sentinel.fileSystemRepresentation, [treeRoot stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0,
                      @"replacement link");
            }, &removed, &unitPath, &error);
            NSArray *asideLeft = [fm contentsOfDirectoryAtPath:treeAside error:nil];
            check(!treeOK && swapped && removed == 1 && error.length, @"root replaced during progress: delete fails closed");
            check(has([treeRoot stringByAppendingPathComponent:@"f1"], @"replacement1") && has([treeRoot stringByAppendingPathComponent:@"f2"], @"replacement2") &&
                  [fm fileExistsAtPath:[treeRoot stringByAppendingPathComponent:@"link"]] && has(sentinel, @"outside"),
                  @"replacement tree untouched");
            check(asideLeft.count == 1 && [asideLeft.firstObject hasPrefix:@"f"] &&
                  has([treeAside stringByAppendingPathComponent:asideLeft.firstObject],
                      [asideLeft.firstObject isEqual:@"f1"] ? @"original1" : @"original2"), @"original's remaining child untouched");
            check(unitPath && [[fm subpathsOfDirectoryAtPath:unitPath error:nil] filteredArrayUsingPredicate:
                               [NSPredicate predicateWithFormat:@"SELF ENDSWITH '/f1' OR SELF ENDSWITH '/f2'"]].count == 1,
                  @"only the removed original file was backed up");
            [fm removeItemAtPath:treeRoot error:nil];
            [fm removeItemAtPath:treeAside error:nil];

            // A nested folder replaced while its children are being visited.
            NSString *nestedRoot = [base stringByAppendingPathComponent:@"nested-root"];
            NSString *sub = [nestedRoot stringByAppendingPathComponent:@"sub"];
            NSString *subAside = [base stringByAppendingPathComponent:@"sub-original"];
            mkdirs(sub);
            put([sub stringByAppendingPathComponent:@"inner"], @"inner-original");
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"deleteTreeChild"] && [path isEqual:[sub stringByAppendingPathComponent:@"inner"]] &&
                    ![fm fileExistsAtPath:subAside]) {
                    check(rename(sub.fileSystemRepresentation, subAside.fileSystemRepresentation) == 0, @"move nested folder aside");
                    mkdirs(sub);
                    put([sub stringByAppendingPathComponent:@"inner"], @"inner-replacement");
                }
            };
            check(!wq_delete_tree(nestedRoot, nil, nil, NULL, NULL, &error) &&
                  has([sub stringByAppendingPathComponent:@"inner"], @"inner-replacement") &&
                  has([subAside stringByAppendingPathComponent:@"inner"], @"inner-original"), @"nested folder replacement fails closed");
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:nestedRoot error:nil];
            [fm removeItemAtPath:subAside error:nil];

            // A link replaced by a regular file right before it is unlinked.
            NSString *linkRoot = [base stringByAppendingPathComponent:@"link-root"];
            NSString *linkChild = [linkRoot stringByAppendingPathComponent:@"child-link"];
            mkdirs(linkRoot);
            check(symlink(sentinel.fileSystemRepresentation, linkChild.fileSystemRepresentation) == 0, @"child link fixture");
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"deleteTreeUnlink"] && [path isEqual:linkChild]) {
                    check(unlink(linkChild.fileSystemRepresentation) == 0, @"remove link in window");
                    put(linkChild, @"no backup for me");
                }
            };
            check(!wq_delete_tree(linkRoot, nil, nil, NULL, NULL, &error) && has(linkChild, @"no backup for me"),
                  @"replaced link entry is not removed without a backup");
            wq_test_tree_hook = nil;

            // The root replaced right before its final removal.
            NSString *emptyRoot = [base stringByAppendingPathComponent:@"empty-root"];
            NSString *emptyAside = [base stringByAppendingPathComponent:@"empty-root-original"];
            mkdirs(emptyRoot);
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"deleteTreeRemoveDir"] && [path isEqual:emptyRoot]) {
                    check(rename(emptyRoot.fileSystemRepresentation, emptyAside.fileSystemRepresentation) == 0, @"move empty root aside");
                    mkdirs(emptyRoot);
                }
            };
            check(!wq_delete_tree(emptyRoot, nil, nil, NULL, NULL, &error) && [fm fileExistsAtPath:emptyRoot] &&
                  [fm fileExistsAtPath:emptyAside], @"replacement root is not removed");
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:emptyRoot error:nil];
            [fm removeItemAtPath:emptyAside error:nil];

            // Selected identity: a tree replaced between selection and delete.
            mkdirs(emptyRoot);
            NSDictionary *selected = wq_item_identity(emptyRoot);
            check(rmdir(emptyRoot.fileSystemRepresentation) == 0, @"remove selected folder");
            mkdirs(emptyRoot);
            put([emptyRoot stringByAppendingPathComponent:@"new"], @"new");
            check(!wq_delete_tree_expecting(emptyRoot, selected, nil, nil, NULL, NULL, &error) &&
                  has([emptyRoot stringByAppendingPathComponent:@"new"], @"new"), @"tree delete refuses a replaced selection");
            check(wq_delete_tree_expecting(emptyRoot, wq_item_identity(emptyRoot), nil, nil, NULL, NULL, &error) &&
                  ![fm fileExistsAtPath:emptyRoot], @"tree delete with a current identity succeeds");

            // CR-02 (backup store): a unit replaced after it was examined.
            NSString *unitA = [wq_test_backup_root stringByAppendingPathComponent:@"20261112-180000-000-1"];
            NSString *unitAside = [base stringByAppendingPathComponent:@"unit-original"];
            mkdirs([unitA stringByAppendingPathComponent:@"private"]);
            put([unitA stringByAppendingPathComponent:@"private/old"], @"old backup");
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"deleteBackupPurge"]) {
                    check(rename(path.fileSystemRepresentation, unitAside.fileSystemRepresentation) == 0, @"move unit aside");
                    mkdirs(path);
                    put([path stringByAppendingPathComponent:@"newer"], @"newer backup");
                }
            };
            check(!wq_delete_backup(unitA, &error) && has([unitA stringByAppendingPathComponent:@"newer"], @"newer backup") &&
                  has([unitAside stringByAppendingPathComponent:@"private/old"], @"old backup"), @"backup unit replacement fails closed");
            wq_test_tree_hook = nil;
            check(wq_delete_backup(unitA, &error) && ![fm fileExistsAtPath:unitA], @"backup unit delete still works");

            // CR-04: non-regular delete, rename and move carry the selected identity.
            NSString *link = [base stringByAppendingPathComponent:@"selected-link"];
            check(symlink("/etc/hosts", link.fileSystemRepresentation) == 0, @"selected link fixture");
            NSDictionary *linkId = wq_item_identity(link);
            check(unlink(link.fileSystemRepresentation) == 0 && symlink("/etc/passwd", link.fileSystemRepresentation) == 0, @"replace link");
            check(!wq_delete_expecting(link, linkId, &error) && [fm destinationOfSymbolicLinkAtPath:link error:nil].length,
                  @"replaced link is not deleted");
            linkId = wq_item_identity(link);
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"deleteReady"] && [path isEqual:link]) {
                    check(unlink(link.fileSystemRepresentation) == 0 && mkfifo(link.fileSystemRepresentation, 0600) == 0, @"swap link for a pipe");
                }
            };
            struct stat lst;
            check(!wq_delete_expecting(link, linkId, &error) && lstat(link.fileSystemRepresentation, &lst) == 0 && S_ISFIFO(lst.st_mode),
                  @"entry swapped right before unlink is kept");
            wq_test_tree_hook = nil;
            check(wq_delete_expecting(link, wq_item_identity(link), &error) && lstat(link.fileSystemRepresentation, &lst) != 0,
                  @"current special entry deletes");

            NSString *renSrc = [base stringByAppendingPathComponent:@"ren-src"];
            NSString *renDst = [base stringByAppendingPathComponent:@"ren-dst"];
            put(renSrc, @"selected");
            NSDictionary *renId = wq_item_identity(renSrc);
            check(unlink(renSrc.fileSystemRepresentation) == 0, @"remove selected source");
            put(renSrc, @"replacement");
            check(!wq_rename_expecting(renSrc, renDst.lastPathComponent, renId, &error) && has(renSrc, @"replacement") &&
                  ![fm fileExistsAtPath:renDst], @"rename refuses a replaced source");
            renId = wq_item_identity(renSrc);
            NSString *renAside = [base stringByAppendingPathComponent:@"ren-aside"];
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"renameReady"] && [path isEqual:renDst]) {
                    check(rename(renSrc.fileSystemRepresentation, renAside.fileSystemRepresentation) == 0, @"move source aside in window");
                    put(renSrc, @"late replacement");
                }
            };
            check(!wq_rename_expecting(renSrc, renDst.lastPathComponent, renId, &error) && has(renSrc, @"late replacement") &&
                  ![fm fileExistsAtPath:renDst] && has(renAside, @"replacement"), @"rename of a late replacement is put back");
            wq_test_tree_hook = nil;
            check(wq_rename_expecting(renSrc, renDst.lastPathComponent, wq_item_identity(renSrc), &error) && has(renDst, @"late replacement"),
                  @"rename with a current identity succeeds");

            NSString *moveDir = [base stringByAppendingPathComponent:@"move-dest"];
            mkdirs(moveDir);
            NSString *moveSrc = [base stringByAppendingPathComponent:@"move-src"];
            put(moveSrc, @"picked");
            NSDictionary *moveId = wq_item_identity(moveSrc);
            check(unlink(moveSrc.fileSystemRepresentation) == 0, @"remove picked source");
            put(moveSrc, @"other");
            check(!wq_move_expecting(moveSrc, moveDir, moveId, &error) && has(moveSrc, @"other") &&
                  ![fm fileExistsAtPath:[moveDir stringByAppendingPathComponent:@"move-src"]], @"Move Here refuses a replaced source");
            moveId = wq_item_identity(moveSrc);
            NSString *moveAside = [base stringByAppendingPathComponent:@"move-aside"];
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"moveReady"] && [path isEqual:moveSrc]) {
                    check(rename(moveSrc.fileSystemRepresentation, moveAside.fileSystemRepresentation) == 0, @"move source aside before move");
                    put(moveSrc, @"late other");
                }
            };
            check(!wq_move_expecting(moveSrc, moveDir, moveId, &error) && has(moveSrc, @"late other") &&
                  ![fm fileExistsAtPath:[moveDir stringByAppendingPathComponent:@"move-src"]], @"move of a late replacement is put back");
            wq_test_tree_hook = nil;
            check(wq_move_expecting(moveSrc, moveDir, wq_item_identity(moveSrc), &error) &&
                  has([moveDir stringByAppendingPathComponent:@"move-src"], @"late other"), @"move with a current identity succeeds");

            // Regular delete: the existing post-backup barrier still rejects a replacement.
            NSString *regular = [base stringByAppendingPathComponent:@"regular-delete"];
            NSString *regularAside = [base stringByAppendingPathComponent:@"regular-aside"];
            put(regular, @"backed up");
            wq_test_mutation_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"backedUp"] && [path isEqual:regular]) {
                    check(rename(regular.fileSystemRepresentation, regularAside.fileSystemRepresentation) == 0, @"move regular aside after backup");
                    put(regular, @"never backed up");
                }
            };
            check(!wq_delete(regular, &error) && has(regular, @"never backed up"), @"regular delete keeps a post-backup replacement");
            wq_test_mutation_hook = nil;
        } @finally {
            wq_test_tree_hook = nil;
            wq_test_mutation_hook = nil;
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
