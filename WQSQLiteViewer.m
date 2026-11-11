//
//  WQSQLiteViewer.m
//  WQ Files
//
//  Read-only SQLite viewer. The database and its -wal file are copied into a
//  private temporary folder first (a -shm file is rebuilt by SQLite there),
//  then opened with PRAGMA query_only. Every statement is checked with
//  sqlite3_stmt_readonly before it runs.
//

#import "WQSQLiteViewer.h"
#import "WQAccess.h"
#import "WQSharing.h"
#import "WQUI.h"
#import <sqlite3.h>

BOOL wq_is_sqlite_header(NSData *head)
{
    return head.length >= 16 && memcmp(head.bytes, "SQLite format 3\0", 16) == 0;
}

static const NSUInteger kWQSQLitePage = 100;
static const NSUInteger kWQSQLiteQueryLimit = 1000;

#pragma mark - Snapshot

// A private copy of the database. All SQLite calls run on its serial queue.
@interface WQSQLiteSnapshot : NSObject
@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic, readonly, nullable) sqlite3 *db;
@property (nonatomic, copy, readonly) NSString *sourcePath;
@property (nonatomic, readonly) BOOL copiedWAL;
@end

@implementation WQSQLiteSnapshot {
    NSString *_dir;
}

// Streams `src` into `dst` through wq_read_range (which asks for access when
// needed). Returns NO with an error text on failure.
static BOOL wq_sqlite_copy(NSString *src, NSString *dst, NSString **error)
{
    if (![NSFileManager.defaultManager createFileAtPath:dst contents:nil attributes:nil]) {
        *error = @"cannot create the temporary copy";
        return NO;
    }
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:dst];
    if (!out) { *error = @"cannot write the temporary copy"; return NO; }
    const NSUInteger chunk = 1024 * 1024;
    unsigned long long offset = 0;
    BOOL ok = YES;
    @try {
        for (;;) {
            NSString *readError = nil;
            NSData *data = wq_read_range(src, offset, chunk, &readError);
            if (!data) { *error = readError ?: @"read failed"; ok = NO; break; }
            if (data.length) [out writeData:data];
            offset += data.length;
            if (data.length < chunk) break;
        }
    } @catch (NSException *exception) {
        *error = exception.reason ?: @"write failed";
        ok = NO;
    }
    [out closeFile];
    return ok;
}

- (nullable instancetype)initWithPath:(NSString *)path error:(NSString **)error
{
    if (!(self = [super init])) return nil;
    _sourcePath = [path copy];
    _queue = dispatch_queue_create("wqfiles.sqlite", DISPATCH_QUEUE_SERIAL);
    _dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"wq-sqlite-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:nil]) {
        *error = @"cannot create a temporary folder";
        return nil;
    }
    NSString *copy = [_dir stringByAppendingPathComponent:@"db.sqlite"];
    if (!wq_sqlite_copy(path, copy, error)) return nil;
    // Recent changes of WAL databases are still in the -wal file. The -shm
    // index is not copied: SQLite rebuilds it next to the copy.
    NSString *wal = [path stringByAppendingString:@"-wal"];
    struct stat st;
    if (wq_stat(wal, &st) && S_ISREG(st.st_mode) && st.st_size > 0) {
        NSString *walError = nil;
        _copiedWAL = wq_sqlite_copy(wal, [copy stringByAppendingString:@"-wal"], &walError);
        if (!_copiedWAL) wq_log(@"sqlite: -wal of %@ not copied (%@); recent changes may be missing", path, walError);
    }
    // Read-write on the private copy so SQLite can apply the WAL there;
    // query_only and the per-statement check keep it read-only in practice.
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(copy.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc != SQLITE_OK) {
        *error = db ? @(sqlite3_errmsg(db)) : @"cannot open the database";
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_exec(db, "PRAGMA query_only = ON", NULL, NULL, NULL);
    // Fail early on files that only look like databases.
    sqlite3_stmt *probe = NULL;
    rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &probe, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_step(probe);
    sqlite3_finalize(probe);
    if (rc != SQLITE_ROW) {
        *error = @(sqlite3_errmsg(db));
        sqlite3_close(db);
        return nil;
    }
    _db = db;
    return self;
}

- (void)dealloc
{
    if (_db) sqlite3_close(_db);
    if (_dir) [NSFileManager.defaultManager removeItemAtPath:_dir error:nil];
}

@end

#pragma mark - Values

static NSString *wq_sqlite_quote_identifier(NSString *name)
{
    return [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

static NSString *wq_sqlite_hex(const uint8_t *bytes, int length, int limit)
{
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < length && i < limit; i++) [hex appendFormat:@"%02x%s", bytes[i], (i % 4 == 3) ? " " : ""];
    if (length > limit) [hex appendString:@"…"];
    return hex;
}

// A column value as display text; `full` shows long text and blobs in more detail.
static NSString *wq_sqlite_value(sqlite3_stmt *stmt, int column, BOOL full)
{
    switch (sqlite3_column_type(stmt, column)) {
        case SQLITE_NULL: return @"NULL";
        case SQLITE_INTEGER: return [NSString stringWithFormat:@"%lld", sqlite3_column_int64(stmt, column)];
        case SQLITE_FLOAT: return [NSString stringWithFormat:@"%.15g", sqlite3_column_double(stmt, column)];
        case SQLITE_BLOB: {
            const uint8_t *bytes = sqlite3_column_blob(stmt, column);
            int length = sqlite3_column_bytes(stmt, column);
            if (length >= 8 && bytes && memcmp(bytes, "bplist0", 7) == 0)
                return [NSString stringWithFormat:@"<binary plist, %d bytes>", length];
            NSString *hex = bytes ? wq_sqlite_hex(bytes, length, full ? 512 : 16) : @"";
            return [NSString stringWithFormat:@"<%d bytes> %@", length, hex];
        }
        default: {
            const unsigned char *text = sqlite3_column_text(stmt, column);
            NSString *s = text ? [NSString stringWithUTF8String:(const char *)text] : nil;
            if (!s) return @"<text not UTF-8>";
            if (!full && s.length > 200) s = [[s substringToIndex:200] stringByAppendingString:@"…"];
            return s;
        }
    }
}

static NSString *wq_sqlite_csv_field(sqlite3_stmt *stmt, int column)
{
    if (sqlite3_column_type(stmt, column) == SQLITE_NULL) return @"";
    if (sqlite3_column_type(stmt, column) == SQLITE_BLOB) {
        const uint8_t *bytes = sqlite3_column_blob(stmt, column);
        int length = sqlite3_column_bytes(stmt, column);
        NSData *data = bytes ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : [NSData data];
        return [@"base64:" stringByAppendingString:[data base64EncodedStringWithOptions:0]];
    }
    NSString *value = wq_sqlite_value(stmt, column, YES);
    if ([value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@",\"\n\r"]].location == NSNotFound)
        return value;
    return [NSString stringWithFormat:@"\"%@\"", [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

#pragma mark - Row detail

@interface WQSQLiteRowViewController : UITableViewController
- (instancetype)initWithColumns:(NSArray<NSString *> *)columns values:(NSArray<NSString *> *)values title:(NSString *)title;
@end

@implementation WQSQLiteRowViewController {
    NSArray<NSString *> *_columns;
    NSArray<NSString *> *_values;
}

- (instancetype)initWithColumns:(NSArray<NSString *> *)columns values:(NSArray<NSString *> *)values title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _columns = [columns copy];
        _values = [values copy];
        self.title = title;
    }
    return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_columns.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return _columns[(NSUInteger)section]; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"v"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"v"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = _values[(NSUInteger)indexPath.section];
    c.textProperties.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    c.textProperties.numberOfLines = 0;
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    NSString *value = _values[(NSUInteger)indexPath.section];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        return [UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"复制" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                                          identifier:nil handler:^(UIAction *__unused a) {
            UIPasteboard.generalPasteboard.string = value;
        }]]];
    }];
}

@end

#pragma mark - Rows (a table, a view or a query)

@interface WQSQLiteRowsViewController : UITableViewController
- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot sql:(NSString *)sql title:(NSString *)title
                     exportName:(nullable NSString *)exportName limit:(NSUInteger)limit;
@end

@implementation WQSQLiteRowsViewController {
    WQSQLiteSnapshot *_snapshot;
    NSString *_sql;
    NSString *_exportName;
    NSUInteger _limit;            // 0 = page through everything
    NSArray<NSString *> *_columns;
    NSMutableArray<NSArray<NSString *> *> *_rows;
    BOOL _loading, _done;
    NSString *_error;
}

- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot sql:(NSString *)sql title:(NSString *)title
                     exportName:(NSString *)exportName limit:(NSUInteger)limit
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _snapshot = snapshot;
        _sql = [sql copy];
        _exportName = [exportName copy];
        _limit = limit;
        _rows = [NSMutableArray new];
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (_exportName) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"CSV" style:UIBarButtonItemStylePlain
                                                                                 target:self action:@selector(exportCSV:)];
    }
    [self loadMore];
}

- (void)loadMore
{
    if (_loading || _done) return;
    _loading = YES;
    NSUInteger offset = _rows.count;
    NSUInteger page = _limit ? _limit : kWQSQLitePage;
    WQSQLiteSnapshot *snapshot = _snapshot;
    // Tables page with LIMIT/OFFSET; a query (which may be a PRAGMA or EXPLAIN,
    // and can't be wrapped) runs as typed and stops after `_limit` rows.
    NSString *sql = _limit ? _sql : [NSString stringWithFormat:@"SELECT * FROM (%@) LIMIT %lu OFFSET %lu",
                                     _sql, (unsigned long)page, (unsigned long)offset];
    dispatch_async(snapshot.queue, ^{
        NSMutableArray *columns = [NSMutableArray new];
        NSMutableArray *rows = [NSMutableArray new];
        NSString *error = nil;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
            error = @(sqlite3_errmsg(snapshot.db));
        } else if (!sqlite3_stmt_readonly(stmt)) {
            error = @"此处只能运行只读语句。";
        } else {
            int count = sqlite3_column_count(stmt);
            for (int i = 0; i < count; i++) [columns addObject:@(sqlite3_column_name(stmt, i) ?: "?")];
            int rc = SQLITE_DONE;
            while (rows.count < page && (rc = sqlite3_step(stmt)) == SQLITE_ROW) {
                NSMutableArray *values = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
                for (int i = 0; i < count; i++) [values addObject:wq_sqlite_value(stmt, i, YES)];
                [rows addObject:values];
            }
            if (rows.count < page && rc != SQLITE_DONE) error = @(sqlite3_errmsg(snapshot.db));
        }
        sqlite3_finalize(stmt);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loading = NO;
            if (error) { self->_error = error; self->_done = YES; [self.tableView reloadData]; return; }
            if (!self->_columns) self->_columns = columns;
            [self->_rows addObjectsFromArray:rows];
            if (rows.count < page || self->_limit) self->_done = YES;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_error || (!_rows.count && _done)) ? 1 : (NSInteger)_rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_error || !_columns) return nil;
    NSString *more = _done ? @"" : @"+";
    if (_limit && _rows.count >= _limit) more = [NSString stringWithFormat:@" (first %lu)", (unsigned long)_limit];
    return [NSString stringWithFormat:@"%lu%@ rows · %lu columns", (unsigned long)_rows.count, more, (unsigned long)_columns.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_error || !_rows.count) {
        c.text = _error ?: @"没有行";
        c.textProperties.color = _error ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        c.textProperties.numberOfLines = 0;
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSArray<NSString *> *values = _rows[(NSUInteger)indexPath.row];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSUInteger i = 0; i < values.count && i < _columns.count; i++) {
        NSString *v = values[i];
        if (v.length > 80) v = [[v substringToIndex:80] stringByAppendingString:@"…"];
        [parts addObject:[NSString stringWithFormat:@"%@: %@", _columns[i], v]];
    }
    c.text = parts.firstObject;
    c.secondaryText = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" · "] : nil;
    c.textProperties.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    c.secondaryTextProperties.numberOfLines = 2;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if ((NSUInteger)indexPath.row + 20 >= _rows.count) [self loadMore];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_error || (NSUInteger)indexPath.row >= _rows.count) return;
    WQSQLiteRowViewController *detail = [[WQSQLiteRowViewController alloc]
        initWithColumns:_columns values:_rows[(NSUInteger)indexPath.row]
                  title:[NSString stringWithFormat:@"行 %ld", (long)indexPath.row + 1]];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)exportCSV:(UIBarButtonItem *)sender
{
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSString *sql = _sql;
    NSString *name = [[_exportName stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByAppendingPathExtension:@"csv"];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wq-sqlite-export"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *out = [dir stringByAppendingPathComponent:name];
    sender.enabled = NO;
    dispatch_async(snapshot.queue, ^{
        NSString *error = nil;
        [NSFileManager.defaultManager createFileAtPath:out contents:nil attributes:nil];
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:out];
        sqlite3_stmt *stmt = NULL;
        if (!file) error = @"无法创建 CSV 文件";
        else if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) error = @(sqlite3_errmsg(snapshot.db));
        else if (!sqlite3_stmt_readonly(stmt)) error = @"此处只能运行只读语句。";
        else {
            int count = sqlite3_column_count(stmt);
            NSMutableArray *header = [NSMutableArray new];
            for (int i = 0; i < count; i++) [header addObject:@(sqlite3_column_name(stmt, i) ?: "?")];
            [file writeData:[[[header componentsJoinedByString:@","] stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                @autoreleasepool {
                    NSMutableArray *fields = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
                    for (int i = 0; i < count; i++) [fields addObject:wq_sqlite_csv_field(stmt, i)];
                    [file writeData:[[[fields componentsJoinedByString:@","] stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                }
            }
        }
        sqlite3_finalize(stmt);
        [file closeFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            if (error) { wq_alert(self, @"无法导出", error); return; }
            wq_share(self, out, nil);
        });
    });
}

@end

#pragma mark - Query

@interface WQSQLiteQueryViewController : UIViewController
- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot;
@end

@implementation WQSQLiteQueryViewController {
    WQSQLiteSnapshot *_snapshot;
    UITextView *_textView;
}

- (instancetype)initWithSnapshot:(WQSQLiteSnapshot *)snapshot
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _snapshot = snapshot;
        self.title = @"SQL";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.text = @"SELECT name, type FROM sqlite_master";
    [self.view addSubview:_textView];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_textView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"运行" style:UIBarButtonItemStyleProminent
                                                                             target:self action:@selector(run)];
    [_textView becomeFirstResponder];
}

- (void)run
{
    NSString *sql = [_textView.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([sql hasSuffix:@";"]) sql = [[sql substringToIndex:sql.length - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!sql.length) return;
    // Only a single read-only statement: checked before anything runs.
    WQSQLiteSnapshot *snapshot = _snapshot;
    __block NSString *error = nil;
    dispatch_sync(snapshot.queue, ^{
        sqlite3_stmt *stmt = NULL;
        const char *tail = NULL;
        if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, &tail) != SQLITE_OK) error = @(sqlite3_errmsg(snapshot.db));
        else if (!stmt) error = @"没有可运行的内容。";
        else if (!sqlite3_stmt_readonly(stmt)) error = @"此处只能运行只读语句（SELECT、只读 PRAGMA、EXPLAIN）。";
        else if (tail && *tail) {
            NSString *rest = [@(tail) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (rest.length) error = @"一次只能运行一条语句。";
        }
        else if (sqlite3_column_count(stmt) == 0) error = @"此语句不返回任何行。";
        sqlite3_finalize(stmt);
    });
    if (error) { wq_alert(self, @"无法运行", error); return; }
    WQSQLiteRowsViewController *rows = [[WQSQLiteRowsViewController alloc] initWithSnapshot:snapshot sql:sql title:@"结果"
                                                                                 exportName:@"query" limit:kWQSQLiteQueryLimit];
    [self.navigationController pushViewController:rows animated:YES];
}

@end

#pragma mark - Tables

@implementation WQSQLiteViewController {
    NSString *_path;
    WQSQLiteSnapshot *_snapshot;
    NSArray<NSDictionary *> *_tables;   // name, type, rows (NSNumber, filled in later)
    NSMutableDictionary<NSString *, NSNumber *> *_counts;
    NSString *_error;
    BOOL _loading;
}

- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _path = [path copy];
        _counts = [NSMutableDictionary new];
        _loading = YES;
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"SQL" style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(openQuery)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    NSString *path = _path;
    dispatch_async(wq_io_interactive(), ^{   // snapshot copy + open (read-only load path)
        NSString *error = nil;
        WQSQLiteSnapshot *snapshot = [[WQSQLiteSnapshot alloc] initWithPath:path error:&error];
        NSMutableArray *tables = [NSMutableArray new];
        if (snapshot) {
            dispatch_sync(snapshot.queue, ^{
                sqlite3_stmt *stmt = NULL;
                if (sqlite3_prepare_v2(snapshot.db, "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY type, name",
                                       -1, &stmt, NULL) == SQLITE_OK) {
                    while (sqlite3_step(stmt) == SQLITE_ROW) {
                        const unsigned char *name = sqlite3_column_text(stmt, 0), *type = sqlite3_column_text(stmt, 1);
                        if (name && type) [tables addObject:@{ @"name": @((const char *)name), @"type": @((const char *)type) }];
                    }
                }
                sqlite3_finalize(stmt);
            });
        }
        if (!snapshot) wq_log(@"sqlite: cannot open %@ (%@)", path, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loading = NO;
            self->_snapshot = snapshot;
            self->_tables = tables;
            self->_error = snapshot ? nil : error;
            self.navigationItem.rightBarButtonItem.enabled = snapshot != nil;
            [self.tableView reloadData];
            if (snapshot) [self countRows];
        });
    });
}

// Row counts for tables, one at a time in the background (big tables take a while).
- (void)countRows
{
    WQSQLiteSnapshot *snapshot = _snapshot;
    NSArray *tables = _tables;
    __weak typeof(self) weakSelf = self;
    dispatch_async(snapshot.queue, ^{
        for (NSDictionary *table in tables) {
            if (!weakSelf) return;
            if (![table[@"type"] isEqualToString:@"table"]) continue;
            NSString *sql = [@"SELECT count(*) FROM " stringByAppendingString:wq_sqlite_quote_identifier(table[@"name"])];
            sqlite3_stmt *stmt = NULL;
            long long count = -1;
            if (sqlite3_prepare_v2(snapshot.db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW)
                count = sqlite3_column_int64(stmt, 0);
            sqlite3_finalize(stmt);
            NSString *name = table[@"name"];
            dispatch_async(dispatch_get_main_queue(), ^{
                WQSQLiteViewController *strongSelf = weakSelf;
                if (!strongSelf || count < 0) return;
                strongSelf->_counts[name] = @(count);
                [strongSelf.tableView reloadData];
            });
        }
    });
}

- (void)openQuery
{
    if (!_snapshot) return;
    [self.navigationController pushViewController:[[WQSQLiteQueryViewController alloc] initWithSnapshot:_snapshot] animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_loading || _error || !_tables.count) ? 1 : (NSInteger)_tables.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return _tables.count ? @"表和视图" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_snapshot) return nil;
    NSString *wal = _snapshot.copiedWAL ? @"（含 -wal 文件）" : @"";
    return [NSString stringWithFormat:@"只读。这是打开时制作的数据库%@副本；应用自己的文件不会被更改。请先关闭应用以获取最新副本。", wal];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"t"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"t"];
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (_loading) {
        c.text = @"正在复制并打开…";
    } else if (_error) {
        c.text = [@"无法打开此数据库：" stringByAppendingString:_error];
        c.textProperties.color = UIColor.systemRedColor;
        c.textProperties.numberOfLines = 0;
    } else if (!_tables.count) {
        c.text = @"没有表";
        c.textProperties.color = UIColor.secondaryLabelColor;
    } else {
        NSDictionary *table = _tables[(NSUInteger)indexPath.row];
        BOOL view = [table[@"type"] isEqualToString:@"view"];
        c.text = table[@"name"];
        c.image = [UIImage systemImageNamed:view ? @"eye" : @"tablecells"];
        NSNumber *count = _counts[table[@"name"]];
        c.secondaryText = view ? @"视图" : (count ? [NSString stringWithFormat:@"%@ 行", count] : @"…");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_snapshot || (NSUInteger)indexPath.row >= _tables.count) return;
    NSString *name = _tables[(NSUInteger)indexPath.row][@"name"];
    NSString *sql = [@"SELECT * FROM " stringByAppendingString:wq_sqlite_quote_identifier(name)];
    WQSQLiteRowsViewController *rows = [[WQSQLiteRowsViewController alloc] initWithSnapshot:_snapshot sql:sql title:name
                                                                                 exportName:name limit:0];
    [self.navigationController pushViewController:rows animated:YES];
}

@end
