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
// Interactive reads: directory/list loading and small read operations
// (page loads, document loads). Concurrent, USER_INITIATED, so a long
// archive or scan on wq_io()/wq_io_scan() cannot block them.
dispatch_queue_t wq_io_interactive(void);
// Full scans (Apps/Cache tree scans, row counting, …). Serial, UTILITY:
// background work that must not compete with interactive reads or writes.
dispatch_queue_t wq_io_scan(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
// Applies the frosted-glass chrome to the navigation bar and toolbar
// (system-material blur). Call once at launch.
void wq_apply_frosted_chrome(void);
NSString *wq_size_text(unsigned long long size);
UIView *wq_device_header(CGFloat width);
// "iPhone 17 Pro Max (iPhone18,2) · iOS 27.0.1 (24A446)"
NSString *wq_device_line(void);
UIImage *_Nullable wq_app_icon(NSString *_Nullable bundleID);

NS_ASSUME_NONNULL_END
