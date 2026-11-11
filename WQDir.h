//
//  WQDir.h
//  WQ Files folder browser interface
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQDirViewController : UITableViewController <UIDocumentPickerDelegate, UISearchResultsUpdating>
@property (nonatomic) BOOL readOnly;
- (instancetype)initWithPath:(NSString *)path title:(NSString *_Nullable)title;
@end

NS_ASSUME_NONNULL_END
