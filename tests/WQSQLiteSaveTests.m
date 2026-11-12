// Saving an edited copy back over a WAL database on the host: the app's
// pending WAL changes and the edit must both survive, the old WAL must be
// emptied, and changed sources or hot journals must be refused untouched.
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#import "../WQSQLiteSave.m"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

static void exec(sqlite3 *db, const char *sql)
{
    char *err = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) { fprintf(stderr, "sql: %s: %s\n", sql, err); exit(1); }
}

// An "app" database in WAL mode whose last rows are only in the -wal file,
// as when the app is killed.
static void makeAppDB(NSString *path)
{
    sqlite3 *db = NULL;
    check(sqlite3_open(path.fileSystemRepresentation, &db) == SQLITE_OK, @"create app database");
    exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;"
             "CREATE TABLE notes(id INTEGER PRIMARY KEY, text TEXT);"
             "INSERT INTO notes(text) VALUES ('one'),('two');");
    exec(db, "PRAGMA wal_checkpoint(TRUNCATE)");
    exec(db, "INSERT INTO notes(text) VALUES ('three, only in the WAL')");
    sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, NULL);
    sqlite3_close(db);
}

static NSArray<NSString *> *texts(NSString *path)
{
    sqlite3 *db = NULL;
    NSMutableArray *out = [NSMutableArray new];
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return out;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT text FROM notes ORDER BY id", -1, &stmt, NULL) == SQLITE_OK)
        while (sqlite3_step(stmt) == SQLITE_ROW) [out addObject:@((const char *)sqlite3_column_text(stmt, 0))];
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return out;
}

static unsigned long long sizeOf(NSString *path)
{
    struct stat st;
    return stat(path.fileSystemRepresentation, &st) == 0 ? (unsigned long long)st.st_size : 0;
}

// The viewer's copy: main + -wal into a private folder, opened read-write.
static sqlite3 *openCopy(NSString *original, NSString *copy)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:copy error:nil];
    [fm removeItemAtPath:[copy stringByAppendingString:@"-wal"] error:nil];
    [fm removeItemAtPath:[copy stringByAppendingString:@"-shm"] error:nil];
    check([fm copyItemAtPath:original toPath:copy error:nil], @"copy main file");
    NSString *wal = [original stringByAppendingString:@"-wal"];
    if (sizeOf(wal)) check([fm copyItemAtPath:wal toPath:[copy stringByAppendingString:@"-wal"] error:nil], @"copy -wal");
    sqlite3 *db = NULL;
    check(sqlite3_open_v2(copy.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK, @"open copy");
    return db;
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQSQLiteSaveTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        check([fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil], @"fixture folder");
        wq_test_backup_root = [base stringByAppendingPathComponent:@"Backups"];
        wq_test_app_backup_root = [base stringByAppendingPathComponent:@"AppBackups"];
        NSString *app = [base stringByAppendingPathComponent:@"app.sqlite"];
        NSString *copy = [base stringByAppendingPathComponent:@"copy/db.sqlite"];
        [fm createDirectoryAtPath:copy.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];

        makeAppDB(app);
        check(sizeOf([app stringByAppendingString:@"-wal"]) > 0, @"app has pending WAL frames");
        NSDictionary *state = wq_sqlite_source_state(app);
        check(state != nil && state[@"wal"] != NSNull.null, @"state records main and -wal");
        struct stat before;
        check(stat(app.fileSystemRepresentation, &before) == 0, @"stat app database");

        sqlite3 *db = openCopy(app, copy);
        exec(db, "UPDATE notes SET text='TWO (edited)' WHERE id=2; DELETE FROM notes WHERE id=1;");
        NSDictionary *after = nil;
        NSString *unit = nil, *error = nil;
        check(wq_sqlite_save(db, copy, app, state, &after, &unit, &error), [@"save succeeds " stringByAppendingString:error ?: @""]);
        check([texts(app) isEqualToArray:@[@"TWO (edited)", @"three, only in the WAL"]], @"edit and the app's WAL-only row are both in the saved database");
        check(sizeOf([app stringByAppendingString:@"-wal"]) == 0, @"old -wal emptied");
        struct stat saved;
        check(stat(app.fileSystemRepresentation, &saved) == 0 && saved.st_ino == before.st_ino, @"database written in place (same inode)");
        check(unit.length && [fm fileExistsAtPath:unit], @"previous database kept in Backups");
        check(after && ![after isEqualToDictionary:state], @"new state returned for the next save");

        // A second edit saves against the new state.
        exec(db, "INSERT INTO notes(text) VALUES ('four')");
        check(wq_sqlite_save(db, copy, app, after, &after, NULL, &error), @"second save succeeds");
        check([texts(app).lastObject isEqualToString:@"four"], @"second edit saved");

        // The app wrote meanwhile: refuse, change nothing.
        sqlite3 *appDB = NULL;
        sqlite3_open(app.fileSystemRepresentation, &appDB);
        exec(appDB, "INSERT INTO notes(text) VALUES ('from the app')");
        sqlite3_close(appDB);
        NSArray *appRows = texts(app);
        exec(db, "INSERT INTO notes(text) VALUES ('stale edit')");
        check(!wq_sqlite_save(db, copy, app, after, NULL, NULL, &error) && [texts(app) isEqualToArray:appRows],
              @"save refused after the app changed the database");
        sqlite3_close(db);

        // A hot rollback journal: refuse.
        NSDictionary *fresh = wq_sqlite_source_state(app);
        db = openCopy(app, copy);
        NSString *journal = [app stringByAppendingString:@"-journal"];
        [@"unfinished" writeToFile:journal atomically:YES encoding:NSUTF8StringEncoding error:nil];
        check(!wq_sqlite_save(db, copy, app, fresh, NULL, NULL, &error) && [error containsString:@"-journal"], @"hot journal refused");
        [fm removeItemAtPath:journal error:nil];
        check(wq_sqlite_save(db, copy, app, fresh, NULL, NULL, &error), @"saves once the journal is gone");
        sqlite3_close(db);

        // The saved database is sound for the app.
        sqlite3_open(app.fileSystemRepresentation, &appDB);
        sqlite3_stmt *stmt = NULL;
        sqlite3_prepare_v2(appDB, "PRAGMA integrity_check", -1, &stmt, NULL);
        BOOL ok = sqlite3_step(stmt) == SQLITE_ROW && strcmp((const char *)sqlite3_column_text(stmt, 0), "ok") == 0;
        sqlite3_finalize(stmt);
        sqlite3_close(appDB);
        check(ok, @"app database passes integrity_check");

        [fm removeItemAtPath:base error:nil];
        puts("All SQLite save tests passed.");
    }
    return 0;
}
