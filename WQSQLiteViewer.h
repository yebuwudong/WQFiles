//
//  WQSQLiteViewer.h
//  WQ Files
//
//  SQLite viewer and editor: tables and views, rows, single-row details,
//  SQL queries and CSV export. Works on a private copy of the database (and
//  its -wal file) in WQ Files' temporary folder. Edit changes that copy; only
//  Save writes it back over the app's database (see WQSQLiteSave.h).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQSQLiteViewController : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
// readOnly: no Edit (backups, read-only places).
- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly;
@end

// Whether the first bytes of a file are an SQLite 3 header.
BOOL wq_is_sqlite_header(NSData *head);

NS_ASSUME_NONNULL_END
