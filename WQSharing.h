//
//  WQSharing.h
//  WQ Files temporary exports and share sheets
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void wq_share(UIViewController *host, NSString *path, UIView *_Nullable source);
void wq_share_folder(UIViewController *host, NSString *dir, NSString *_Nullable zipName, UIView *_Nullable source);
void wq_share_cancel(UIViewController *host);
// At launch: removes WQShare-* export folders older than an hour that an
// earlier run left behind (a crash or kill skips their normal cleanup).
void wq_share_sweep_stale_exports(void);

NS_ASSUME_NONNULL_END
