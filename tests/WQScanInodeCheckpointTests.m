// Deterministic resolver tests the parallel scanner's durable contiguous frontier.
#define WQ_ACCESS_TESTING 1
#define fsgetpath WQFixtureGetPath
#import "../WQAccess.m"
#undef fsgetpath
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }
static NSString *mode;
static _Atomic unsigned long calls;
ssize_t WQFixtureGetPath(char *buffer, size_t size, fsid_t *fsid, uint64_t inode)
{
    (void)fsid;
    atomic_fetch_add(&calls, 1);
    if (([mode isEqual:@"prefix-crash"] && inode == 32769) || ([mode isEqual:@"gap-crash"] && inode == 1)) {
        // Let the other worker commit its chunk; the process is then killed.
        dispatch_semaphore_wait(dispatch_semaphore_create(0), DISPATCH_TIME_FOREVER);
    }
    if ([mode isEqual:@"prefix-resume"] && inode > 1 && inode < 32769) {
        fprintf(stderr, "FAIL: committed prefix was scanned again\n"); _exit(2);
    }
    NSString *path = inode == 1 ? @"/checkpoint-root/first" : inode == 40000 ? @"/checkpoint-root/second" : nil;
    if (!path) { errno = ENOENT; return -1; }
    strlcpy(buffer, path.UTF8String, size);
    return (ssize_t)strlen(buffer);
}
static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static void run(NSString *argument, int expected)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
    task.arguments = @[argument];
    check([task launchAndReturnError:nil], @"launch inode scan process");
    [task waitUntilExit];
    check(task.terminationStatus == expected, argument);
}
int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *key = @"inodes:/checkpoint-root";
        if (argc > 1) {
            mode = @(argv[1]);
            fsid_t fsid = {{1, 2}};
            NSArray *found = wq_scan_children(fsid, 1, 65536, @[@"/checkpoint-root"], nil, QOS_CLASS_UTILITY, NO,
                ^(int64_t __unused done, int64_t __unused total, const NSUInteger *__unused counts) {
                    if ([mode hasSuffix:@"crash"]) _exit(25);
                }, nil);
            check([found.firstObject count] == 2, @"resume merges hits without omission or double counting");
            if ([mode isEqual:@"prefix-resume"]) check(atomic_load(&calls) < 33000, @"committed prefix is not re-executed");
            if ([mode isEqual:@"gap-resume"]) check(atomic_load(&calls) < 33000, @"only the missing chunk is replayed; completed later range is reused");
            return 0;
        }
        for (NSString *kind in @[@"prefix", @"gap"]) {
            WQScanJournalRemove(key);
            run([kind stringByAppendingString:@"-crash"], 25);
            NSDictionary *saved = WQScanJournalLoad(key);
            check([saved[@"next"] longLongValue] == ([kind isEqual:@"prefix"] ? 32769 : 1), @"checkpoint advances only over contiguous completed ranges");
            run([kind stringByAppendingString:@"-resume"], 0);
        }
        // A corrupt payload must fall back to scanning, never skip a range.
        WQScanJournalSave(key, @{@"next": @"invalid", @"found": @"invalid"});
        run(@"corrupt-resume", 0);
        WQScanJournalRemove(key);
        puts("All inode checkpoint tests passed.");
    }
    return 0;
}
