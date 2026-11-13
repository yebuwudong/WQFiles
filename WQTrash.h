//
//  WQTrash.h
//  WQ Files
//
//  Recently Deleted: the backups (Backups/<stamp>/<original path>) of files
//  whose original no longer exists, newest backup per original path. Nothing
//  is stored separately; deleting or overwriting already backs files up.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQDeletedItem : NSObject
@property (nonatomic, copy) NSString *backupPath;     // the backed-up file
@property (nonatomic, copy) NSString *originalPath;   // where it was
@property (nonatomic, copy) NSString *unitPath;       // Backups/<stamp>, what Delete Permanently removes
@property (nonatomic) NSUInteger unitFileCount;       // files in that unit (a deleted folder has several)
@property (nonatomic, strong) NSDate *date;           // when the backup was made
@property (nonatomic) unsigned long long size;
@end

// Newest first. Checks every original path (asks for access where needed),
// so call it off the main thread.
NSArray<WQDeletedItem *> *wq_recently_deleted(void);
// As wq_recently_deleted, but tells a failure apart from "nothing deleted":
// nil (with *problem) when Backups cannot be listed; a list plus *problem when
// some backup units could not be read completely.
NSArray<WQDeletedItem *> *_Nullable wq_recently_deleted_checked(NSString *_Nullable *_Nullable problem);

// Puts the file back at its original path, creating missing parent folders.
// Fails if something is at that path already; on failure, removes the
// folders it created again (only while they are still empty).
BOOL wq_restore_deleted(WQDeletedItem *item, NSString *_Nullable *_Nullable errorText);

// The date in a backup unit name ("20261111-175959-512-1"), or nil.
NSDate *_Nullable wq_backup_stamp_date(NSString *stamp);

NS_ASSUME_NONNULL_END
