//
//  WQUI.h
//  WQ Files shared UI helpers
//

#import <UIKit/UIKit.h>
#import "WQLocalization.h"

NS_ASSUME_NONNULL_BEGIN

static inline UIBarButtonItemStyle wq_primary_button_style(void)
{
    if (@available(iOS 26.0, *)) return UIBarButtonItemStyleProminent;
    return UIBarButtonItemStylePlain;
}

dispatch_queue_t wq_io(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
// Settings → Allow Deleting (on by default). When off, every delete, clear and
// clean action is hidden or refused.
BOOL wq_deleting_allowed(void);
void wq_set_deleting_allowed(BOOL allowed);
// Settings → Keep Data Before Restore (on by default). When off, the safety
// backup an app restore makes first is deleted once the restore succeeded.
BOOL wq_keep_before_restore(void);
void wq_set_keep_before_restore(BOOL keep);
// YES (after telling the user) when deleting is turned off.
BOOL wq_refuse_if_deleting_off(UIViewController *host);
// title/message/action titles are localization keys. Pass already-localized
// text and raw data (names, keys, error strings) as WQVerbatim(text) so it is
// shown exactly and never looked up a second time.
UIAlertController *wq_alert_controller(NSString *_Nullable title, NSString *_Nullable message, UIAlertControllerStyle style);
UIAlertAction *wq_alert_action(NSString *title, UIAlertActionStyle style, void (^_Nullable handler)(UIAlertAction *));
NSString *wq_size_text(unsigned long long size);
// "WQ Files <version> (<build>)".
NSString *wq_app_version_line(void);
// Height of the strip wq_device_header draws (16 pt of space follow it).
extern const CGFloat kWQDeviceStripHeight;
UIView *wq_device_header(CGFloat width);
// "iPhone 17 Pro Max (iPhone18,2) · iOS 27.0.1 (24A446)"
NSString *wq_device_line(void);
UIImage *_Nullable wq_app_icon(NSString *_Nullable bundleID);
// WQ Prism: a soft layered backdrop shared by the redesigned screens.
UIView *wq_prism_background_view(void);
void wq_prism_install_background(UIViewController *vc);
// Settings → New Design: WQ Prism (default) or the classic list design.
BOOL wq_prism_enabled(void);
void wq_set_prism_enabled(BOOL enabled);
// Settings → Plain Background (issue #56): the WQ Prism screens on a plain
// system background instead of the colored glows. Switching it updates every
// backdrop at once.
BOOL wq_prism_plain_background(void);
void wq_set_prism_plain_background(BOOL plain);



// Read-only scan orchestration runs separately from mutations. Directory-sized
// measurement steps rejoin wq_io(), so foreground requests can run between them.
// Registered at launch: scans pause when WQ Files goes to the background,
// unless keepRunning() says a full scan still has background time.
void wq_scan_lifecycle_install(BOOL (*_Nullable keepRunning)(void));
void wq_scan_pause_for_background(void);
dispatch_queue_t wq_scan_queue(void);
void wq_scan_read(void (^work)(void));
// Marks a tab while its scan runs or waits for another scan: a gray "…" or "◷"
// badge on iPhone; on iPad the floating tab bar always draws badges red, so the
// title gets an animated braille spinner (⠋⠙⠹…) or a clock (◷) instead.
typedef NS_ENUM(NSInteger, WQTabBusy) { WQTabBusyNone, WQTabBusyRunning, WQTabBusyWaiting };
@class WQScanTask;
BOOL wq_scan_task_waiting(WQScanTask *task);
// Section header with the status text and, while fraction >= 0, a progress bar.
@interface WQProgressHeaderView : UITableViewHeaderFooterView
- (void)setText:(nullable NSString *)text fraction:(float)fraction;
@end
void wq_set_tab_busy(UIViewController *tabRoot, NSString *title, WQTabBusy state);

NS_ASSUME_NONNULL_END
