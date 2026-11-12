//
//  WQSQLiteSave.h
//  WQ Files
//
//  Writes an edited private copy of an SQLite database back over another
//  app's database. The copy holds everything (its WAL is checkpointed into
//  it), so after the main file is written in place the app's old -wal and
//  -shm are emptied: otherwise SQLite would replay stale WAL frames on top of
//  the new file and corrupt it. Refuses when the app changed the files since
//  the copy was made or left a hot rollback journal; if emptying the old WAL
//  fails, the original database is put back. The app must not be running.
//

#import <Foundation/Foundation.h>
#import <sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

// The versions of `path` and its -wal (NSNull when there is none), recorded
// when the copy is made and compared again before saving. Nil if the
// database itself can't be read.
NSDictionary *_Nullable wq_sqlite_source_state(NSString *path);

// Checkpoints and checks `copyDB` (the open private copy at `copyPath`), then
// writes it over `original` and empties the original's -wal and -shm.
// `state` is what wq_sqlite_source_state returned when the copy was made;
// *newState gets the state after saving (for the next save), *backupUnit the
// Backups folder holding the previous database.
BOOL wq_sqlite_save(sqlite3 *copyDB, NSString *copyPath, NSString *original, NSDictionary *state,
                    NSDictionary *_Nullable *_Nullable newState, NSString *_Nullable *_Nullable backupUnit,
                    NSString *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
