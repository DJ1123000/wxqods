//
//  WQSharing.h
//  WQ Files temporary exports and share sheets
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void wq_share(UIViewController *host, NSString *path, UIView *_Nullable source);
void wq_share_folder(UIViewController *host, NSString *dir, NSString *_Nullable zipName, UIView *_Nullable source);
void wq_share_cancel(UIViewController *host);

NS_ASSUME_NONNULL_END
