#include <sys/stat.h>
// Host tests for WQArchive: round trips, compatibility with zip/unzip/ditto and
// Python's zipfile (including ZIP64 records), and refusal of unsafe archives.
#import <Foundation/Foundation.h>
#import "../WQArchive.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; NSLog(@"FAIL line %d: %s", __LINE__, #cond); __VA_OPT__(NSLog(__VA_ARGS__);) } } while (0)

static int run(NSString *tool, NSArray<NSString *> *args, NSString *cwd)
{
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:tool];
    t.arguments = args;
    if (cwd) t.currentDirectoryURL = [NSURL fileURLWithPath:cwd];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) return -1;
    [t waitUntilExit];
    return t.terminationStatus;
}

static NSString *tmpdir(NSString *name)
{
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%@", name, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void put(NSString *path, NSData *data)
{
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:NO];
}

static NSData *randomData(NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithLength:n];
    arc4random_buf(d.mutableBytes, n);
    return d;
}

static BOOL sameTree(NSString *a, NSString *b)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *la = [[fm subpathsOfDirectoryAtPath:a error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSArray *lb = [[fm subpathsOfDirectoryAtPath:b error:nil] sortedArrayUsingSelector:@selector(compare:)];
    if (![la isEqualToArray:lb]) { NSLog(@"trees differ:\n%@\n%@", la, lb); return NO; }
    for (NSString *rel in la) {
        BOOL dir = NO;
        [fm fileExistsAtPath:[a stringByAppendingPathComponent:rel] isDirectory:&dir];
        if (dir) continue;
        if (![[NSData dataWithContentsOfFile:[a stringByAppendingPathComponent:rel]]
              isEqualToData:[NSData dataWithContentsOfFile:[b stringByAppendingPathComponent:rel]]]) {
            NSLog(@"contents differ: %@", rel); return NO;
        }
    }
    return YES;
}

static void le16(NSMutableData *d, uint16_t v) { uint8_t b[2] = { (uint8_t)v, (uint8_t)(v >> 8) }; [d appendBytes:b length:2]; }
static void le32(NSMutableData *d, uint32_t v) { le16(d, (uint16_t)v); le16(d, (uint16_t)(v >> 16)); }

// A 22-byte end-of-central-directory record.
static NSData *eocd(uint16_t count, uint32_t cdSize, uint32_t cdOffset, uint16_t commentLen)
{
    NSMutableData *d = [NSMutableData new];
    le32(d, 0x06054b50); le16(d, 0); le16(d, 0); le16(d, count); le16(d, count);
    le32(d, cdSize); le32(d, cdOffset); le16(d, commentLen);
    return d;
}

// `zip` (no comment yet) with `comment` appended and its length set.
static NSData *withComment(NSData *zip, NSData *comment)
{
    NSMutableData *d = [zip mutableCopy];
    uint16_t n = (uint16_t)comment.length;
    uint8_t b[2] = { (uint8_t)n, (uint8_t)(n >> 8) };
    [d replaceBytesInRange:NSMakeRange(d.length - 2, 2) withBytes:b];
    [d appendData:comment];
    return d;
}

// A ZIP of `count` empty stored files named by `name(i)` (central directory
// only points at local headers that exist).
static NSData *manyEntries(NSUInteger count, NSString *(^name)(NSUInteger i))
{
    NSMutableData *local = [NSMutableData new], *cd = [NSMutableData new];
    for (NSUInteger i = 0; i < count; i++) {
        NSData *n = [name(i) dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t offset = (uint32_t)local.length;
        le32(local, 0x04034b50); le16(local, 20); le16(local, 0); le16(local, 0); le16(local, 0); le16(local, 0x21);
        le32(local, 0); le32(local, 0); le32(local, 0); le16(local, (uint16_t)n.length); le16(local, 0);
        [local appendData:n];
        le32(cd, 0x02014b50); le16(cd, 20); le16(cd, 20); le16(cd, 0); le16(cd, 0); le16(cd, 0); le16(cd, 0x21);
        le32(cd, 0); le32(cd, 0); le32(cd, 0); le16(cd, (uint16_t)n.length); le16(cd, 0); le16(cd, 0);
        le16(cd, 0); le16(cd, 0); le32(cd, 0); le32(cd, offset);
        [cd appendData:n];
    }
    NSMutableData *zip = [local mutableCopy];
    [zip appendData:cd];
    if (count > 0xFFFF) {   // ZIP64 end record and locator
        uint64_t recPos = zip.length;
        le32(zip, 0x06064b50); le32(zip, 44); le32(zip, 0); le16(zip, 45); le16(zip, 45); le32(zip, 0); le32(zip, 0);
        le32(zip, (uint32_t)count); le32(zip, 0); le32(zip, (uint32_t)count); le32(zip, 0);
        le32(zip, (uint32_t)cd.length); le32(zip, 0); le32(zip, (uint32_t)local.length); le32(zip, 0);
        le32(zip, 0x07064b50); le32(zip, 0); le32(zip, (uint32_t)recPos); le32(zip, (uint32_t)(recPos >> 32)); le32(zip, 1);
        [zip appendData:eocd(0xFFFF, 0xFFFFFFFFu, 0xFFFFFFFFu, 0)];
        return zip;
    }
    [zip appendData:eocd((uint16_t)count, (uint32_t)cd.length, (uint32_t)local.length, 0)];
    return zip;
}

static NSString *python(NSString *script, NSString *cwd)
{
    NSString *py = [cwd stringByAppendingPathComponent:@"make.py"];
    [script writeToFile:py atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return run(@"/usr/bin/python3", @[@"-I", py], cwd) == 0 ? cwd : nil;
}

int main(void)
{
    @autoreleasepool {
        WQArchiveIO *io = wq_archive_posix_io();
        NSFileManager *fm = NSFileManager.defaultManager;

        // Safe names.
        CHECK([wq_zip_safe_entry_path(@"a/b/c.txt") isEqualToString:@"a/b/c.txt"]);
        CHECK([wq_zip_safe_entry_path(@"a\\b.txt") isEqualToString:@"a/b.txt"]);
        CHECK([wq_zip_safe_entry_path(@"dir/") isEqualToString:@"dir"]);
        CHECK(wq_zip_safe_entry_path(@"../x") == nil);
        CHECK(wq_zip_safe_entry_path(@"a/../../x") == nil);
        CHECK(wq_zip_safe_entry_path(@"/etc/passwd") == nil);
        CHECK(wq_zip_safe_entry_path(@"C:/x") == nil);
        CHECK(wq_zip_safe_entry_path(@"./x") == nil);
        CHECK(wq_zip_safe_entry_path(@"") == nil);

        // Fixture: nested folders, an empty folder, an empty file, a big
        // random file, Unicode names, and a symbolic link (left out).
        NSString *src = tmpdir(@"src");
        NSString *tree = [src stringByAppendingPathComponent:@"Folder"];
        put([tree stringByAppendingPathComponent:@"a.txt"], [@"hello hello hello hello" dataUsingEncoding:NSUTF8StringEncoding]);
        put([tree stringByAppendingPathComponent:@"sub/deeper/b.bin"], randomData(3 * 1024 * 1024 + 17));
        put([tree stringByAppendingPathComponent:@"sub/empty.dat"], [NSData data]);
        put([tree stringByAppendingPathComponent:@"Grüße 日本.txt"], [@"unicode" dataUsingEncoding:NSUTF8StringEncoding]);
        [fm createDirectoryAtPath:[tree stringByAppendingPathComponent:@"emptydir"] withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createSymbolicLinkAtPath:[tree stringByAppendingPathComponent:@"link"] withDestinationPath:@"/etc/hosts" error:nil];
        NSString *single = [src stringByAppendingPathComponent:@"single.txt"];
        put(single, [@"just one file" dataUsingEncoding:NSUTF8StringEncoding]);

        // Round trip: folder + file into one archive.
        NSString *work = tmpdir(@"work");
        NSString *zip = [work stringByAppendingPathComponent:@"Archive.zip"];
        NSString *err = nil;
        NSUInteger skipped = 0;
        __block unsigned long long lastProgress = 0;
        BOOL ok = wq_zip_write(@[tree, single], zip, io, nil, ^(unsigned long long b) { lastProgress = b; }, &skipped, &err);
        CHECK(ok, @"zip write: %@", err);
        CHECK(skipped == 1, @"skipped %lu", (unsigned long)skipped);
        CHECK(lastProgress >= 3 * 1024 * 1024, @"progress %llu", lastProgress);
        CHECK(run(@"/usr/bin/unzip", @[@"-tqq", zip], nil) == 0, @"unzip -t rejects our ZIP");

        // The system's unzip sees the same tree (minus the link).
        NSString *viaUnzip = tmpdir(@"viaunzip");
        CHECK(run(@"/usr/bin/unzip", @[@"-qq", zip, @"-d", viaUnzip], nil) == 0);
        NSString *expected = tmpdir(@"expected");
        [fm copyItemAtPath:tree toPath:[expected stringByAppendingPathComponent:@"Folder"] error:nil];
        [fm removeItemAtPath:[expected stringByAppendingPathComponent:@"Folder/link"] error:nil];
        [fm copyItemAtPath:single toPath:[expected stringByAppendingPathComponent:@"single.txt"] error:nil];
        CHECK(sameTree(expected, viaUnzip), @"unzip output differs");

        // Our extractor.
        NSString *out = tmpdir(@"out");
        NSUInteger files = 0;
        __block unsigned long long extracted = 0;
        ok = wq_zip_extract(zip, out, io, 1ull << 40, nil, ^(unsigned long long b) { extracted = b; }, &files, &skipped, &err);
        CHECK(ok, @"extract: %@", err);
        CHECK(files == 5, @"files %lu", (unsigned long)files);
        CHECK(sameTree(expected, out), @"extract output differs");
        CHECK(extracted == 3 * 1024 * 1024 + 17 + 23 + 7 + 13, @"extracted bytes %llu", extracted);

        // Existing destination file name is refused (O_EXCL), not overwritten.
        CHECK(![fm fileExistsAtPath:[work stringByAppendingPathComponent:@"x"]]);
        CHECK(!wq_zip_write(@[single], zip, io, nil, nil, nil, &err), @"overwrote an existing zip");

        // Free-space limit.
        NSString *small = tmpdir(@"small");
        CHECK(!wq_zip_extract(zip, small, io, 1024, nil, nil, nil, nil, &err), @"size limit ignored");
        CHECK([fm contentsOfDirectoryAtPath:small error:nil].count == 0, @"size limit wrote files");

        // Cancellation removes the partial ZIP.
        NSString *cancelled = [work stringByAppendingPathComponent:@"cancel.zip"];
        CHECK(!wq_zip_write(@[tree], cancelled, io, ^BOOL { return YES; }, nil, nil, &err));
        CHECK(![fm fileExistsAtPath:cancelled], @"cancelled zip left behind");

        // Duplicate top-level names are refused.
        NSString *other = tmpdir(@"other");
        put([other stringByAppendingPathComponent:@"single.txt"], [NSData data]);
        CHECK(!wq_zip_write(@[single, [other stringByAppendingPathComponent:@"single.txt"]],
                            [work stringByAppendingPathComponent:@"dup.zip"], io, nil, nil, nil, &err));

        // Archives made by zip(1) and ditto (data descriptors, __MACOSX).
        NSString *zip1 = [work stringByAppendingPathComponent:@"zip1.zip"];
        CHECK(run(@"/usr/bin/zip", @[@"-qry", zip1, @"Folder", @"single.txt"], src) == 0);
        NSString *out1 = tmpdir(@"out1");
        CHECK(wq_zip_extract(zip1, out1, io, 1ull << 40, nil, nil, &files, &skipped, &err), @"zip(1): %@", err);
        CHECK(skipped == 1, @"zip -y link not skipped");
        CHECK(sameTree(expected, out1), @"zip(1) output differs");

        NSString *ditto = [work stringByAppendingPathComponent:@"ditto.zip"];
        CHECK(run(@"/usr/bin/ditto", @[@"-c", @"-k", @"--sequesterRsrc", @"--keepParent", tree, ditto], nil) == 0);
        NSString *out2 = tmpdir(@"out2");
        CHECK(wq_zip_extract(ditto, out2, io, 1ull << 40, nil, nil, &files, &skipped, &err), @"ditto: %@", err);
        NSString *expectedFolder = tmpdir(@"expfolder");
        [fm copyItemAtPath:[expected stringByAppendingPathComponent:@"Folder"] toPath:[expectedFolder stringByAppendingPathComponent:@"Folder"] error:nil];
        CHECK(sameTree(expectedFolder, out2), @"ditto output differs");

        // Python: ZIP64 records, stored entries, an unsafe name, an encrypted flag.
        NSString *py = tmpdir(@"py");
        CHECK(python(@"import zipfile\n"
                     "with zipfile.ZipFile('z64.zip','w',zipfile.ZIP_DEFLATED) as z:\n"
                     "    with z.open('big/x.txt','w',force_zip64=True) as f: f.write(b'x'*100000)\n"
                     "    z.writestr(zipfile.ZipInfo('stored.txt'), b'plain', compress_type=zipfile.ZIP_STORED)\n"
                     "with zipfile.ZipFile('evil.zip','w') as z:\n"
                     "    z.writestr('ok.txt', b'fine')\n"
                     "    z.writestr('../escape.txt', b'bad')\n"
                     "with zipfile.ZipFile('enc.zip','w') as z:\n"
                     "    i = zipfile.ZipInfo('secret.txt'); i.flag_bits |= 1\n"
                     "    z.writestr(i, b'xx')\n"
                     "d = bytearray(open('enc.zip','rb').read())\n"
                     "for sig, off in ((b'PK\\x03\\x04', 6), (b'PK\\x01\\x02', 8)):\n"
                     "    k = d.find(sig); d[k + off] |= 1\n"
                     "open('enc.zip','wb').write(d)\n"
                     "with zipfile.ZipFile('crc.zip','w',zipfile.ZIP_STORED) as z: z.writestr('c.txt', b'abcdef')\n"
                     "d = bytearray(open('crc.zip','rb').read()); j = d.find(b'abcdef'); d[j] ^= 1; open('crc.zip','wb').write(d)\n", py) != nil,
              @"python fixture failed");
        NSString *out3 = tmpdir(@"out3");
        CHECK(wq_zip_extract([py stringByAppendingPathComponent:@"z64.zip"], out3, io, 1ull << 40, nil, nil, &files, nil, &err), @"zip64: %@", err);
        CHECK([[NSData dataWithContentsOfFile:[out3 stringByAppendingPathComponent:@"big/x.txt"]] length] == 100000);
        CHECK([[NSString stringWithContentsOfFile:[out3 stringByAppendingPathComponent:@"stored.txt"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"plain"]);

        NSString *out4 = tmpdir(@"out4");
        CHECK(!wq_zip_extract([py stringByAppendingPathComponent:@"evil.zip"], out4, io, 1ull << 40, nil, nil, nil, nil, &err), @"unsafe zip extracted");
        CHECK([fm contentsOfDirectoryAtPath:out4 error:nil].count == 0, @"unsafe zip wrote files");
        CHECK(![fm fileExistsAtPath:[out4.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"escape.txt"]]);

        NSString *out5 = tmpdir(@"out5");
        CHECK(!wq_zip_extract([py stringByAppendingPathComponent:@"enc.zip"], out5, io, 1ull << 40, nil, nil, nil, nil, &err), @"encrypted zip extracted");

        NSString *out6 = tmpdir(@"out6");
        CHECK(!wq_zip_extract([py stringByAppendingPathComponent:@"crc.zip"], out6, io, 1ull << 40, nil, nil, nil, nil, &err), @"bad CRC accepted");
        CHECK([err containsString:@"checksum"], @"crc error text: %@", err);

        // Not a ZIP / truncated.
        NSString *junk = [work stringByAppendingPathComponent:@"junk.zip"];
        put(junk, randomData(5000));
        CHECK(!wq_zip_extract(junk, tmpdir(@"out7"), io, 1ull << 40, nil, nil, nil, nil, &err));
        NSData *whole = [NSData dataWithContentsOfFile:zip];
        NSString *cut = [work stringByAppendingPathComponent:@"cut.zip"];
        put(cut, [whole subdataWithRange:NSMakeRange(0, whole.length / 2)]);
        CHECK(!wq_zip_extract(cut, tmpdir(@"out8"), io, 1ull << 40, nil, nil, nil, nil, &err));

        // Unreadable files and folders (like a container's root-only metadata
        // plist): fail the archive by default, left out with skipUnreadable.
        NSString *locked = [tmpdir(@"locked") stringByAppendingPathComponent:@"Container"];
        NSString *secret = [locked stringByAppendingPathComponent:@".metadata.plist"];
        NSString *closed = [locked stringByAppendingPathComponent:@"Closed"];
        put([locked stringByAppendingPathComponent:@"Documents/save.dat"], [@"progress" dataUsingEncoding:NSUTF8StringEncoding]);
        put(secret, [@"root only" dataUsingEncoding:NSUTF8StringEncoding]);
        put([closed stringByAppendingPathComponent:@"inner.txt"], [@"x" dataUsingEncoding:NSUTF8StringEncoding]);
        chmod(secret.fileSystemRepresentation, 0);
        chmod(closed.fileSystemRepresentation, 0);
        NSString *strict = [work stringByAppendingPathComponent:@"strict.zip"];
        CHECK(!wq_zip_write(@[locked], strict, io, nil, nil, nil, &err), @"unreadable file must fail without skipUnreadable");
        CHECK(![fm fileExistsAtPath:strict], @"failed ZIP removed");
        WQArchiveIO *lenient = wq_archive_posix_io();
        lenient.skipUnreadable = YES;
        NSString *shareZip = [work stringByAppendingPathComponent:@"share.zip"];
        CHECK(wq_zip_write(@[locked], shareZip, lenient, nil, nil, nil, &err), @"lenient zip: %@", err);
        CHECK(lenient.unreadable == 2, @"unreadable %lu", (unsigned long)lenient.unreadable);
        NSString *shareOut = tmpdir(@"shareout");
        CHECK(wq_zip_extract(shareZip, shareOut, io, 1ull << 40, nil, nil, nil, nil, &err), @"extract: %@", err);
        CHECK([[NSData dataWithContentsOfFile:[shareOut stringByAppendingPathComponent:@"Container/Documents/save.dat"]]
               isEqual:[@"progress" dataUsingEncoding:NSUTF8StringEncoding]], @"readable file kept");
        CHECK(![fm fileExistsAtPath:[shareOut stringByAppendingPathComponent:@"Container/.metadata.plist"]], @"unreadable file left out");
        chmod(closed.fileSystemRepresentation, 0755);
        chmod(secret.fileSystemRepresentation, 0644);

        // CR-18: only a refusal (EACCES/EPERM) is skipped; any other listing
        // failure fails even a lenient archive.
        for (NSNumber *code in @[@(EACCES), @(EPERM), @(EIO), @(ENOENT), @0]) {
            WQArchiveIO *failing = wq_archive_posix_io();
            failing.skipUnreadable = YES;
            NSArray *(^plain)(NSString *) = failing.list;
            failing.list = ^NSArray<NSString *> *(NSString *dir) {
                if ([dir.lastPathComponent isEqualToString:@"Documents"]) { errno = code.intValue; return nil; }
                return plain(dir);
            };
            NSString *listZip = [work stringByAppendingPathComponent:[NSString stringWithFormat:@"list-%d.zip", code.intValue]];
            BOOL refusal = code.intValue == EACCES || code.intValue == EPERM;
            err = nil;
            BOOL wrote = wq_zip_write(@[locked], listZip, failing, nil, nil, nil, &err);
            CHECK(wrote == refusal, @"list errno %d: wrote %d (%@)", code.intValue, wrote, err);
            CHECK(refusal ? failing.unreadable == 1 : ![fm fileExistsAtPath:listZip], @"list errno %d: unreadable %lu",
                  code.intValue, (unsigned long)failing.unreadable);
        }
        // The POSIX list reports the real reason.
        NSString *noDir = [work stringByAppendingPathComponent:@"no-such-dir"];
        errno = 0;
        CHECK(io.list(noDir) == nil && errno != EACCES && errno != EPERM && errno != 0, @"posix list errno %d", errno);
        chmod(closed.fileSystemRepresentation, 0);
        errno = 0;
        CHECK(io.list(closed) == nil && (errno == EACCES || errno == EPERM), @"posix list refusal errno %d", errno);
        chmod(closed.fileSystemRepresentation, 0755);

        // CR-16: an EOCD-shaped record inside the comment must not win.
        NSString *eo = tmpdir(@"eocd");
        NSString *plainZip = [eo stringByAppendingPathComponent:@"plain.zip"];
        CHECK(wq_zip_write(@[single], plainZip, io, nil, nil, nil, &err), @"plain zip: %@", err);
        NSData *plainData = [NSData dataWithContentsOfFile:plainZip];
        // Ordinary comment.
        NSString *commented = [eo stringByAppendingPathComponent:@"commented.zip"];
        put(commented, withComment(plainData, [@"just a comment" dataUsingEncoding:NSUTF8StringEncoding]));
        NSString *outC = tmpdir(@"outC");
        CHECK(wq_zip_extract(commented, outC, io, 1ull << 40, nil, nil, &files, nil, &err) && files == 1, @"comment: %@", err);
        // Comment ending in an all-zero EOCD (the reproduced case): the real entry extracts.
        NSMutableData *fakeComment = [[@"note: " dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [fakeComment appendData:eocd(0, 0, 0, 0)];
        NSString *fake = [eo stringByAppendingPathComponent:@"fake.zip"];
        put(fake, withComment(plainData, fakeComment));
        NSString *outF = tmpdir(@"outF");
        files = 0;
        CHECK(wq_zip_extract(fake, outF, io, 1ull << 40, nil, nil, &files, nil, &err), @"fake eocd: %@", err);
        CHECK(files == 1 && [[NSString stringWithContentsOfFile:[outF stringByAppendingPathComponent:@"single.txt"]
                                                       encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"just one file"],
              @"fake eocd hid the real entry (files %lu)", (unsigned long)files);
        // A fake that is self-consistent (empty directory ending at itself): ambiguous, refused.
        NSMutableData *selfComment = [[@"note: " dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        uint32_t fakePos = (uint32_t)(plainData.length + selfComment.length);
        [selfComment appendData:eocd(0, 0, fakePos, 0)];
        NSString *ambiguous = [eo stringByAppendingPathComponent:@"ambiguous.zip"];
        put(ambiguous, withComment(plainData, selfComment));
        NSString *outA = tmpdir(@"outA");
        err = nil;
        CHECK(!wq_zip_extract(ambiguous, outA, io, 1ull << 40, nil, nil, nil, nil, &err) && [err containsString:@"ambiguous"],
              @"ambiguous eocd: %@", err);
        CHECK([fm contentsOfDirectoryAtPath:outA error:nil].count == 0, @"ambiguous zip wrote files");
        // A comment that doesn't reach the end of the file is not an EOCD.
        NSMutableData *trailing = [plainData mutableCopy];
        [trailing appendData:[@"garbage" dataUsingEncoding:NSUTF8StringEncoding]];
        NSString *trail = [eo stringByAppendingPathComponent:@"trailing.zip"];
        put(trail, trailing);
        CHECK(!wq_zip_extract(trail, tmpdir(@"outT"), io, 1ull << 40, nil, nil, nil, nil, &err), @"trailing garbage accepted");
        // An empty archive is still fine.
        NSString *empty = [eo stringByAppendingPathComponent:@"empty.zip"];
        put(empty, eocd(0, 0, 0, 0));
        files = 7;
        CHECK(wq_zip_extract(empty, tmpdir(@"outE"), io, 1ull << 40, nil, nil, &files, nil, &err) && files == 0, @"empty zip: %@", err);

        // CR-17: entry count and path limits, refused before anything is written.
        NSString *many = [eo stringByAppendingPathComponent:@"many.zip"];
        put(many, manyEntries(kWQZipMaxEntries + 1, ^NSString *(NSUInteger i) { return [NSString stringWithFormat:@"%lu", (unsigned long)i]; }));
        NSString *outM = tmpdir(@"outM");
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        err = nil;
        CHECK(!wq_zip_extract(many, outM, io, 1ull << 40, nil, nil, nil, nil, &err) && [err containsString:@"too many"], @"many: %@", err);
        CHECK([fm contentsOfDirectoryAtPath:outM error:nil].count == 0, @"too-many zip wrote files");
        printf("over-limit entry count refused in %.3f s\n", CFAbsoluteTimeGetCurrent() - t0);
        // A 16-bit count that doesn't cover the whole directory (no ZIP64) is damaged, not truncated.
        NSMutableData *wrapped = [manyEntries(3, ^NSString *(NSUInteger i) { return [NSString stringWithFormat:@"w%lu", (unsigned long)i]; }) mutableCopy];
        uint8_t two[2] = { 2, 0 };
        [wrapped replaceBytesInRange:NSMakeRange(wrapped.length - 14, 2) withBytes:two];
        [wrapped replaceBytesInRange:NSMakeRange(wrapped.length - 12, 2) withBytes:two];
        NSString *wrappedZip = [eo stringByAppendingPathComponent:@"wrapped.zip"];
        put(wrappedZip, wrapped);
        CHECK(!wq_zip_extract(wrappedZip, tmpdir(@"outW"), io, 1ull << 40, nil, nil, nil, nil, &err), @"short count accepted");
        NSString *atLimit = [eo stringByAppendingPathComponent:@"limit.zip"];
        put(atLimit, manyEntries(2000, ^NSString *(NSUInteger i) { return [NSString stringWithFormat:@"d/%lu", (unsigned long)i]; }));
        NSString *outL = tmpdir(@"outL");
        CHECK(wq_zip_extract(atLimit, outL, io, 1ull << 40, nil, nil, &files, nil, &err) && files == 2000, @"2000 entries: %@", err);
        NSMutableArray *parts = [NSMutableArray new];
        for (int i = 0; i < kWQZipMaxPathDepth + 1; i++) [parts addObject:@"d"];
        NSString *deepName = [parts componentsJoinedByString:@"/"];
        NSString *deep = [eo stringByAppendingPathComponent:@"deep.zip"];
        put(deep, manyEntries(1, ^NSString *(NSUInteger __unused i) { return deepName; }));
        NSString *outD = tmpdir(@"outD");
        CHECK(!wq_zip_extract(deep, outD, io, 1ull << 40, nil, nil, nil, nil, &err) && [err containsString:@"too deep"], @"deep: %@", err);
        CHECK([fm contentsOfDirectoryAtPath:outD error:nil].count == 0, @"deep zip wrote files");
        NSMutableArray *longParts = [NSMutableArray new];
        for (int i = 0; i < 6; i++) [longParts addObject:[@"" stringByPaddingToLength:200 withString:@"x" startingAtIndex:0]];
        NSString *longName = [longParts componentsJoinedByString:@"/"];
        NSString *longZip = [eo stringByAppendingPathComponent:@"long.zip"];
        put(longZip, manyEntries(1, ^NSString *(NSUInteger __unused i) { return longName; }));
        NSString *outLong = tmpdir(@"outLong");
        CHECK(!wq_zip_extract(longZip, outLong, io, 1ull << 40, nil, nil, nil, nil, &err) && [err containsString:@"too long"], @"long: %@", err);
        CHECK([fm contentsOfDirectoryAtPath:outLong error:nil].count == 0, @"long zip wrote files");
    }
    if (failures) { printf("WQArchiveTests: %d failure(s)\n", failures); return 1; }
    printf("WQArchiveTests: all passed\n");
    return 0;
}
