//
//  WQEditing.h
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Editors implement this so Back, Home and the interactive edge swipe protect
// unsaved changes. Root plist editors prompt for a dirty document; child
// plist editors intentionally keep the shared document's edits.
@protocol WQUnsavedEditing <NSObject>
- (BOOL)wq_needsLeaveConfirmation;
- (void)confirmLeaveThen:(void (^)(void))proceed;
@end

NS_ASSUME_NONNULL_END
