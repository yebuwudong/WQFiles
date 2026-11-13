//
//  WQSQLiteSave.m
//  WQ Files
//

#import "WQSQLiteSave.h"
#import "WQAccess.h"
#import "WQLocalization.h"
#include <sys/stat.h>

static NSString *wq_sqlite_side(NSString *path, NSString *suffix) { return [path stringByAppendingString:suffix]; }

static BOOL wq_sqlite_side_exists(NSString *path, struct stat *st)
{
    return wq_stat(path, st) && S_ISREG(st->st_mode);
}

NSDictionary *wq_sqlite_source_state(NSString *path)
{
    NSDictionary *main = wq_file_version(path);
    if (!main) return nil;
    struct stat st;
    NSString *wal = wq_sqlite_side(path, @"-wal");
    id walVersion = wq_sqlite_side_exists(wal, &st) ? (wq_file_version(wal) ?: NSNull.null) : NSNull.null;
    return @{ @"main": main, @"wal": walVersion };
}

// One row of a PRAGMA as integers; NO if it didn't run.
static BOOL wq_sqlite_pragma_ints(sqlite3 *db, const char *sql, long long *values, int count)
{
    sqlite3_stmt *stmt = NULL;
    BOOL ok = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW;
    for (int i = 0; ok && i < count; i++) values[i] = sqlite3_column_int64(stmt, i);
    sqlite3_finalize(stmt);
    return ok;
}

static NSString *wq_sqlite_quick_check(sqlite3 *db)
{
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, NULL) != SQLITE_OK) return @(sqlite3_errmsg(db));
    NSString *result = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(stmt, 0);
        result = text ? @((const char *)text) : @"?";
    } else {
        result = @(sqlite3_errmsg(db));
    }
    sqlite3_finalize(stmt);
    return [result isEqualToString:@"ok"] ? nil : result;
}

// A self-contained copy of a database at `dest`: `main` with `wal` (nil when
// there is none) checkpointed into it, checked, and no sidecars left beside it.
static BOOL wq_sqlite_logical_copy(NSString *main, NSString *wal, NSString *dest, NSString **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *destWAL = wq_sqlite_side(dest, @"-wal"), *destSHM = wq_sqlite_side(dest, @"-shm");
    for (NSString *p in @[dest, destWAL, destSHM]) [fm removeItemAtPath:p error:nil];
    NSError *fsError = nil;
    if (![fm copyItemAtPath:main toPath:dest error:&fsError] || (wal && ![fm copyItemAtPath:wal toPath:destWAL error:&fsError])) {
        *error = fsError.localizedDescription ?: @"?";
        return NO;
    }
    sqlite3 *db = NULL;
    BOOL ok = sqlite3_open_v2(dest.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK;
    long long ckpt[3] = {0, 0, 0};
    NSString *problem = nil;
    if (ok && wal && (!wq_sqlite_pragma_ints(db, "PRAGMA wal_checkpoint(TRUNCATE)", ckpt, 3) || ckpt[0] != 0)) ok = NO;
    if (ok && (problem = wq_sqlite_quick_check(db))) ok = NO;
    if (!ok) *error = problem ?: (db ? @(sqlite3_errmsg(db)) : @"?");
    if (sqlite3_close(db) != SQLITE_OK && ok) { ok = NO; *error = @"close"; }
    // The checkpoint emptied the -wal; the main file now holds every row.
    if (ok && wal && (wq_sqlite_side_exists(destWAL, &(struct stat){0}) &&
                      [[fm attributesOfItemAtPath:destWAL error:nil] fileSize] > 0)) {
        ok = NO;
        *error = @"-wal";
    }
    [fm removeItemAtPath:destWAL error:nil];
    [fm removeItemAtPath:destSHM error:nil];
    return ok;
}

static BOOL wq_sqlite_fail(NSString **error, NSString *text)
{
    if (error) *error = text;
    return NO;
}

BOOL wq_sqlite_save(sqlite3 *copyDB, NSString *copyPath, NSString *original, NSDictionary *state,
                    NSDictionary **newState, NSString **backupUnit, NSString **error)
{
    if (newState) *newState = nil;
    if (backupUnit) *backupUnit = nil;
    struct stat st;
    // A rollback journal left by a crash still has to be applied by SQLite:
    // writing now would mix two versions.
    NSString *journal = wq_sqlite_side(original, @"-journal");
    if (wq_sqlite_side_exists(journal, &st) && st.st_size > 0)
        return wq_sqlite_fail(error, WQLocalized(@"The app left an unfinished transaction (a -journal file). Open the app once and close it, then open the database again."));
    NSDictionary *now = wq_sqlite_source_state(original);
    if (!now) return wq_sqlite_fail(error, WQLocalized(@"The database can't be read anymore."));
    if (![now isEqualToDictionary:state])
        return wq_sqlite_fail(error, WQLocalized(@"The app changed the database since it was opened here. Saving would overwrite those changes: discard yours, close the app and open the database again."));

    // Everything into the copy's main file, then make sure it's sound.
    long long ckpt[3] = {0, 0, 0};
    if (!wq_sqlite_pragma_ints(copyDB, "PRAGMA wal_checkpoint(TRUNCATE)", ckpt, 3) || ckpt[0] != 0)
        return wq_sqlite_fail(error, WQLocalizedFormat(@"The copy could not be prepared for saving (%@).", @(sqlite3_errmsg(copyDB))));
    NSString *problem = wq_sqlite_quick_check(copyDB);
    if (problem)
        return wq_sqlite_fail(error, WQLocalizedFormat(@"The edited copy failed SQLite's integrity check, so nothing was saved: %@", problem));

    // Untouched copies of the app's files, to put back if emptying the old
    // WAL fails after the database was written.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"wq-sqlite-save-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *keepMain = [dir stringByAppendingPathComponent:@"main"], *keepWAL = [dir stringByAppendingPathComponent:@"wal"];
    NSString *empty = [dir stringByAppendingPathComponent:@"empty"];
    NSString *wal = wq_sqlite_side(original, @"-wal"), *shm = wq_sqlite_side(original, @"-shm");
    BOOL walExists = wq_sqlite_side_exists(wal, &st);
    BOOL hasWAL = walExists && st.st_size > 0;
    BOOL hasSHM = wq_sqlite_side_exists(shm, &st) && st.st_size > 0;
    NSString *copyError = nil;
    if (!wq_copy_to_local(original, keepMain, &copyError) || (hasWAL && !wq_copy_to_local(wal, keepWAL, &copyError)) ||
        ![fm createFileAtPath:empty contents:[NSData data] attributes:nil]) {
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalizedFormat(@"Could not make a safety copy first: %@", copyError ?: @"?"));
    }
    if (![wq_sqlite_source_state(original) isEqualToDictionary:state]) {
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalized(@"The app changed the database since it was opened here. Saving would overwrite those changes: discard yours, close the app and open the database again."));
    }

    // The previous database for Backups, made before anything is written:
    // the main file with its old WAL checkpointed into it (the WAL may hold
    // committed rows the main file lacks), plus an empty -wal so restoring
    // the whole unit can't leave newer WAL frames on top of it. One unit.
    NSString *logical = [dir stringByAppendingPathComponent:@"previous.sqlite"];
    NSString *unit = nil;
    if (!wq_sqlite_logical_copy(keepMain, hasWAL ? keepWAL : nil, logical, &copyError) ||
        !wq_backup_local_copy(original, logical, &unit, &copyError) ||
        (walExists && !wq_backup_local_copy(wal, empty, &unit, &copyError))) {
        if (unit) wq_delete_backup(unit, NULL);
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalizedFormat(@"Could not make a safety copy first: %@", copyError ?: @"?"));
    }

    // Each write below also keeps the raw previous file in a unit of its own;
    // those are dropped after success, as `unit` holds the whole database.
    NSString *writeError = nil, *rawMain = nil, *rawWAL = nil, *rawSHM = nil;
    if (!wq_write_from_file_with_backup(original, copyPath, &rawMain, &writeError)) {
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, WQLocalizedFormat(@"The database could not be written: %@", writeError ?: @"?"));
    }
    NSString *sideError = nil;
    BOOL sidesOK = (!hasWAL || wq_write_from_file_with_backup(wal, empty, &rawWAL, &sideError)) &&
                   (!hasSHM || wq_write_from_file_with_backup(shm, empty, &rawSHM, &sideError));
    if (!sidesOK) {
        // The new database with the old WAL would be corrupt: put both back.
        NSString *undoError = nil;
        BOOL undone = wq_write_from_file(original, keepMain, &undoError) && (!hasWAL || wq_write_from_file(wal, keepWAL, &undoError));
        wq_log(@"sqlite: emptying the old -wal/-shm of %@ failed (%@); original %@; previous database in %@", original, sideError,
               undone ? @"put back" : [@"NOT put back: " stringByAppendingString:undoError ?: @"?"], unit.lastPathComponent);
        [fm removeItemAtPath:dir error:nil];
        return wq_sqlite_fail(error, undone
            ? WQLocalizedFormat(@"The app's -wal file could not be emptied (%@), so the original database was put back. Nothing changed.", sideError ?: @"?")
            : WQLocalizedFormat(@"The app's -wal file could not be emptied (%@) and the original could not be put back (%@). Restore the database from Backups before opening the app.", sideError ?: @"?", undoError ?: @"?"));
    }
    [fm removeItemAtPath:dir error:nil];
    for (NSString *raw in @[rawMain ?: @"", rawWAL ?: @"", rawSHM ?: @""]) {
        NSString *dropError = nil;
        if (raw.length && ![raw isEqualToString:unit] && !wq_delete_backup(raw, &dropError))
            wq_log(@"sqlite: could not drop the raw backup %@ (%@)", raw.lastPathComponent, dropError ?: @"?");
    }
    wq_log(@"sqlite: saved %@ (backup %@%@)", original, unit.lastPathComponent ?: @"?", hasWAL ? @", old -wal emptied" : @"");
    if (backupUnit) *backupUnit = unit;
    if (newState) *newState = wq_sqlite_source_state(original);
    return YES;
}
