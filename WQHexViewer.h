//
//  WQHexViewer.h
//  WQ Files
//
//  Hex viewer and editor for files of any size: reads in pages on demand,
//  go to offset, find hex or text, overwrite bytes in place (wq_patch, with a
//  backup first). Never changes the file's size.
//

#import <UIKit/UIKit.h>
#import "WQEditing.h"

NS_ASSUME_NONNULL_BEGIN

@interface WQHexViewController : UITableViewController <WQUnsavedEditing>
- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly;
@end

NS_ASSUME_NONNULL_END
