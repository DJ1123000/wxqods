#import <UIKit/UIKit.h>

// Reapplies the pre-restore safety state after an interrupted restore.
// Call on the serial I/O queue before presenting the result to the user.
NSString *_Nullable wq_recover_interrupted_restore(void);

@interface WQAppsViewController : UITableViewController <UISearchResultsUpdating>
@end
