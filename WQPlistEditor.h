//
//  WQPlistEditor.h
//  WQ Files
//
//  Property list editor: browse dictionaries and arrays, edit values by type,
//  add, delete, rename and reorder. Saves in the file's original format through
//  wq_write_if_unchanged_get_version (backup first, verified contents).
//

#import <UIKit/UIKit.h>
#import "WQEditing.h"

NS_ASSUME_NONNULL_BEGIN

@interface WQPlistEditorViewController : UITableViewController <WQUnsavedEditing>
// Loads `path` itself. openAsText / openAsHex (optional) switch to the other
// viewers from the "Open As" menu.
- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly;
@property (nonatomic, copy, nullable) void (^openAsText)(void);
@property (nonatomic, copy, nullable) void (^openAsHex)(void);
@end

NS_ASSUME_NONNULL_END
