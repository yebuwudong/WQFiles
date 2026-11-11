//
//  WQUI.h
//  WQ Files shared UI helpers
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

static inline UIBarButtonItemStyle wq_primary_button_style(void)
{
    if (@available(iOS 26.0, *)) return UIBarButtonItemStyleProminent;
    return UIBarButtonItemStylePlain;
}

dispatch_queue_t wq_io(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
NSString *wq_size_text(unsigned long long size);
UIView *wq_device_header(CGFloat width);
// "iPhone 17 Pro Max (iPhone18,2) · iOS 27.0.1 (24A446)"
NSString *wq_device_line(void);
UIImage *_Nullable wq_app_icon(NSString *_Nullable bundleID);
// 多行的分组标题/说明。中文比英文长，系统自带的 titleForHeaderInSection /
// titleForFooterInSection 只显示一行并加省略号，所以改用自适应高度的视图。
UIView *wq_table_text_header(NSString *_Nullable text, CGFloat width, BOOL isHeader);

NS_ASSUME_NONNULL_END
