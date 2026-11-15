//
//  WQSQLiteSave.h
//  WQ Files
//
//  Installs an edited private copy using SQLite's destination transaction.
//  Refuses changed sources and unfinished rollback journals. The target app
//  must be closed while saving.
//
#import <Foundation/Foundation.h>
#import <sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

// The versions of `path` and its -wal (NSNull when there is none), recorded
// when the copy is made and compared again before saving. Nil if the
// database itself can't be read.
NSDictionary *_Nullable wq_sqlite_source_state(NSString *path);

// Checks the private copy and installs it into `original` through SQLite.
// `state` is what wq_sqlite_source_state returned when the copy was made;
// *newState gets the state after saving (for the next save), *backupUnit the
// Backups folder holding the previous database: one unit with the old main
// file with its old -wal checkpointed into it (so it holds every committed
// row on its own) and, if the app had a -wal, an empty -wal beside it.
// Restoring that unit (or just its main file) restores the whole database.
BOOL wq_sqlite_save(sqlite3 *copyDB, NSString *original, NSDictionary *state,
                    NSDictionary *_Nullable *_Nullable newState, NSString *_Nullable *_Nullable backupUnit,
                    NSString *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
