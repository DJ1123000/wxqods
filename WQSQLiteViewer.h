//
//  WQSQLiteViewer.h
//  WQ Files
//
//  Read-only SQLite viewer: tables and views, rows, single-row details,
//  read-only SQL queries and CSV export. Works on a private copy of the
//  database (and its -wal file) in WQ Files' temporary folder, so the app's
//  own files are never opened for writing and no journal files appear in its
//  container.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQSQLiteViewController : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

// Whether the first bytes of a file are an SQLite 3 header.
BOOL wq_is_sqlite_header(NSData *head);

NS_ASSUME_NONNULL_END
