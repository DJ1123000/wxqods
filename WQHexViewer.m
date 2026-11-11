//
//  WQHexViewer.m
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import "WQHexViewer.h"
#import "WQHexViewerHelpers.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQUI.h"
#import <sys/stat.h>

static const NSUInteger kPageSize = 64 * 1024;
static const NSUInteger kSearchChunk = 1024 * 1024;

static BOOL wqh_is_visible(UIViewController *host)
{
    if (!host.isViewLoaded || !host.view.window) return NO;
    UINavigationController *navigation = host.navigationController;
    return !navigation || navigation.visibleViewController == host;
}

static void wqh_alert(UIViewController *host, NSString *title, NSString *message)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!wqh_is_visible(host)) return;
        UIViewController *presented = host.presentedViewController;
        if (presented && ![presented isKindOfClass:UIAlertController.class]) return;
        void (^present)(void) = ^{
            if (!wqh_is_visible(host) || host.presentedViewController) return;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [host presentViewController:a animated:YES completion:nil];
        };
        if (presented) [presented dismissViewControllerAnimated:YES completion:present];
        else present();
    });
}

@implementation WQHexViewController {
    NSString *_path;
    BOOL _readOnly;
    unsigned long long _size;
    NSUInteger _perRow;
    int _offsetDigits;     // hex digits in the offset column
    NSCache<NSNumber *, NSData *> *_pages;
    NSMutableSet<NSNumber *> *_loading;
    NSMutableDictionary<NSNumber *, NSNumber *> *_edits;   // offset -> new byte
    WQEditState *_editState;
    NSDictionary<NSString *, NSNumber *> *_version;
    unsigned long long _matchOffset;
    NSUInteger _matchLength;
    NSData *_lastSearchNeedle;
    NSUInteger _searchGeneration;
    NSString *_status;
    dispatch_queue_t _queue;
}

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        _readOnly = readOnly;
        _perRow = 8;
        _offsetDigits = 8;
        _pages = [NSCache new];
        _pages.countLimit = 64;   // 4 MB
        _loading = [NSMutableSet new];
        _edits = [NSMutableDictionary new];
        _editState = [WQEditState new];
        _queue = dispatch_queue_create("wqfiles.hex", DISPATCH_QUEUE_SERIAL);
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 20;
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
    NSString *path = _path;
    dispatch_async(_queue, ^{
        struct stat st;
        BOOL ok = wq_stat(path, &st) && S_ISREG(st.st_mode);
        NSDictionary *version = ok ? wq_file_version(path) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_version = version;
            self->_size = ok ? (unsigned long long)st.st_size : 0;
            [self layoutColumns];
            if (wq_permission_hint(path, YES)) self->_readOnly = YES;
            self->_status = ok ? nil : @"无法打开此文件。";
            [self updateBar];
            [self.tableView reloadData];
        });
    });
    [self updateBar];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    _searchGeneration++;
    _lastSearchNeedle = nil;
    _matchLength = 0;
    _status = nil;
}

- (UIFont *)rowFont
{
    return [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
}

// As many bytes per row as fit (in steps of 4), and an offset column only as
// wide as the file needs.
- (void)layoutColumns
{
    int digits = 4;
    for (unsigned long long last = _size ? _size - 1 : 0; digits < 16 && (last >> (4 * digits)); digits++) {}
    CGFloat charWidth = [@"0" sizeWithAttributes:@{ NSFontAttributeName: self.rowFont }].width;
    CGFloat avail = self.tableView.bounds.size.width - 16;   // 8 pt margins on each side
    if (charWidth <= 0 || avail <= 0) return;
    NSInteger chars = (NSInteger)floor(avail / charWidth);
    // A row is: offset, 2 spaces, "xx " per byte, 1 space, 1 character per byte.
    NSInteger fit = (chars - digits - 3) / 4;
    NSUInteger per = (NSUInteger)MAX(4, MIN(32, fit - fit % 4));
    if (per != _perRow || digits != _offsetDigits) {
        _perRow = per;
        _offsetDigits = digits;
        [self.tableView reloadData];
    }
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    [self layoutColumns];
}

- (void)updateBar
{
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)_size countStyle:NSByteCountFormatterCountStyleFile];
    NSString *prompt = _status ?: [NSString stringWithFormat:@"%@ · %llu 字节%@%@", size, _size,
                                   _edits.count ? [NSString stringWithFormat:@" · 已更改 %lu 处", (unsigned long)_edits.count] : @"",
                                   _editState.saving ? @" · 正在保存…" : @""];
    self.navigationItem.prompt = prompt;
    NSMutableArray *items = [NSMutableArray array];
    if (!_readOnly) {
        UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:wq_primary_button_style()
                                                                target:self action:@selector(save)];
        save.enabled = _edits.count > 0 && !_editState.saving;
        [items addObject:save];
    }
    __weak typeof(self) weakSelf = self;
    UIAction *discard = [UIAction actionWithTitle:@"放弃更改" image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil
                                      handler:^(UIAction *__unused a) { [weakSelf discard]; }];
    if (_editState.saving) discard.attributes = UIMenuElementAttributesDisabled;
    UIMenu *menu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:@"跳转到偏移量…" image:[UIImage systemImageNamed:@"arrow.right.to.line"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf goToOffset]; }],
        [UIAction actionWithTitle:@"查找十六进制字节…" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptFindHex:YES]; }],
        [UIAction actionWithTitle:@"查找文本…" image:[UIImage systemImageNamed:@"text.magnifyingglass"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptFindHex:NO]; }],
        discard,
    ]];
    [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu]];
    self.navigationItem.rightBarButtonItems = items;
}

#pragma mark Data

// The file byte at `offset` (an edit if there is one), or -1 while its page
// is still being read.
- (int)byteAt:(unsigned long long)offset
{
    NSNumber *edit = _edits[@(offset)];
    if (edit) return edit.intValue;
    return [self originalByteAt:offset];
}

- (int)originalByteAt:(unsigned long long)offset
{
    NSNumber *page = @(offset / kPageSize);
    NSData *data = [_pages objectForKey:page];
    if (!data) { [self loadPage:page]; return -1; }
    NSUInteger i = (NSUInteger)(offset % kPageSize);
    return i < data.length ? ((const uint8_t *)data.bytes)[i] : -1;
}

- (void)loadPage:(NSNumber *)page
{
    if ([_loading containsObject:page]) return;
    [_loading addObject:page];
    NSString *path = _path;
    dispatch_async(_queue, ^{
        NSString *error = nil;
        NSData *data = wq_read_range(path, page.unsignedLongLongValue * kPageSize, kPageSize, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_loading removeObject:page];
            if (!data) {
                self->_status = wq_permission_hint(path, NO) ? @"Only the owner may read this file." : [NSString stringWithFormat:@"Read failed: %@", error];
                [self updateBar];
                return;
            }
            [self->_pages setObject:data forKey:page];
            [self.tableView reloadRowsAtIndexPaths:self.tableView.indexPathsForVisibleRows
                                  withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)((_size + _perRow - 1) / _perRow);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"h"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"h"];
    UIFont *font = self.rowFont;
    unsigned long long start = (unsigned long long)indexPath.row * _perRow;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%0*llx  ", _offsetDigits, start]
            attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor }];
    NSMutableString *ascii = [NSMutableString new];
    NSMutableArray<NSValue *> *asciiMarks = [NSMutableArray new];
    for (NSUInteger i = 0; i < _perRow; i++) {
        unsigned long long off = start + i;
        if (off >= _size) { [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:@{ NSFontAttributeName: font }]]; continue; }
        int b = [self byteAt:off];
        UIColor *color = UIColor.labelColor;
        BOOL edited = _edits[@(off)] != nil;
        BOOL match = _matchLength && off >= _matchOffset && off < _matchOffset + _matchLength;
        if (edited) color = UIColor.systemOrangeColor;
        NSMutableDictionary *attrs = [@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color } mutableCopy];
        if (match) attrs[NSBackgroundColorAttributeName] = [UIColor.systemYellowColor colorWithAlphaComponent:0.45];
        NSString *hex = b < 0 ? @"·· " : [NSString stringWithFormat:@"%02x ", b];
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:hex attributes:attrs]];
        if (edited || match) [asciiMarks addObject:[NSValue valueWithRange:NSMakeRange(ascii.length, 1)]];
        [ascii appendFormat:@"%c", (b >= 0x20 && b < 0x7f) ? b : '.'];
    }
    NSMutableAttributedString *asc = [[NSMutableAttributedString alloc] initWithString:[@" " stringByAppendingString:ascii]
        attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor }];
    for (NSValue *v in asciiMarks) {
        NSRange r = v.rangeValue;
        [asc addAttribute:NSForegroundColorAttributeName value:UIColor.systemOrangeColor range:NSMakeRange(r.location + 1, 1)];
    }
    [line appendAttributedString:asc];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.attributedText = line;
    c.textProperties.numberOfLines = 1;
    c.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 8, 0, 8);
    cell.contentConfiguration = c;
    cell.selectionStyle = _readOnly ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_readOnly || _editState.saving) return;
    unsigned long long start = (unsigned long long)indexPath.row * _perRow;
    NSUInteger count = (NSUInteger)MIN((unsigned long long)_perRow, _size - start);
    NSMutableString *current = [NSMutableString new];
    for (NSUInteger i = 0; i < count; i++) {
        int b = [self byteAt:start + i];
        if (b < 0) return;   // page not loaded yet
        [current appendFormat:i ? @" %02x" : @"%02x", b];
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"0x%llx 处的字节", start]
        message:[NSString stringWithFormat:@"覆盖这 %lu 个字节（十六进制）。文件大小不变。", (unsigned long)count]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = current;
        f.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
        NSData *bytes = WQParseHex(a.textFields.firstObject.text ?: @"", NO);
        if (bytes.length != count) {
            wqh_alert(self, @"未更改", [NSString stringWithFormat:@"请以十六进制准确输入 %lu 个字节。", (unsigned long)count]);
            return;
        }
        const uint8_t *nb = bytes.bytes;
        for (NSUInteger i = 0; i < count; i++) {
            unsigned long long off = start + i;
            if ([self originalByteAt:off] == nb[i]) [self->_edits removeObjectForKey:@(off)];
            else self->_edits[@(off)] = @(nb[i]);
        }
        [self->_editState noteChange];
        [self updateBar];
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Save, discard, leave

- (BOOL)wq_needsLeaveConfirmation
{
    return _edits.count > 0 || _editState.saving;
}

- (NSDictionary<NSNumber *, NSData *> *)runs
{
    NSMutableDictionary *runs = [NSMutableDictionary new];
    NSArray *offsets = [_edits.allKeys sortedArrayUsingSelector:@selector(compare:)];
    unsigned long long runStart = 0;
    NSMutableData *run = nil;
    for (NSNumber *o in offsets) {
        unsigned long long off = o.unsignedLongLongValue;
        uint8_t b = (uint8_t)_edits[o].intValue;
        if (run && off == runStart + run.length) { [run appendBytes:&b length:1]; continue; }
        if (run) runs[@(runStart)] = run;
        runStart = off;
        run = [NSMutableData dataWithBytes:&b length:1];
    }
    if (run) runs[@(runStart)] = run;
    return runs;
}

- (BOOL)blockWhileSaving
{
    if (!_editState.saving) return NO;
    wqh_alert(self, @"正在保存", @"请等待保存完成后再离开或更改这些编辑。");
    return YES;
}

- (void)save
{
    if (!_edits.count || [self blockWhileSaving]) return;
    if (!_version) {
        wqh_alert(self, @"无法保存", @"无法验证文件版本。请关闭并重新打开后再保存。");
        return;
    }
    NSDictionary *runs = [self runs];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存更改？"
        message:[NSString stringWithFormat:@"%@ 中的 %lu 个字节将被原地覆盖。当前文件会先备份。",
                 _path, (unsigned long)_edits.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        NSDictionary *expectedVersion = [self->_version copy];
        if (!expectedVersion) {
            wqh_alert(self, @"无法保存", @"无法验证文件版本。请关闭并重新打开后再保存。");
            return;
        }
        NSUInteger savedRevision = [self->_editState beginSave];
        [self updateBar];
        NSString *path = self->_path;
        dispatch_async(self->_queue, ^{
            NSString *error = nil;
            NSDictionary *savedVersion = nil;
            BOOL ok = wq_patch_if_unchanged_get_version(path, runs, expectedVersion, &savedVersion, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_editState finishSave:ok revision:savedRevision];
                if (!ok) {
                    [self updateBar];
                    wqh_alert(self, @"保存失败", error ?: wq_permission_hint(path, YES) ?: @"未知错误");
                    return;
                }
                self->_version = savedVersion;
                self->_status = nil;
                if (self->_editState.revision == savedRevision) [self->_edits removeAllObjects];
                [self->_pages removeAllObjects];
                [self updateBar];
                [self.tableView reloadData];
            });
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)discard
{
    if ([self blockWhileSaving]) return;
    [_edits removeAllObjects];
    [_editState discard];
    [self updateBar];
    [self.tableView reloadData];
}

// Home button: ask before throwing away unsaved changes.
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_edits.count) { proceed(); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"放弃更改？"
        message:@"字节更改尚未保存。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        [self->_edits removeAllObjects];
        [self->_editState discard];
        proceed();
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)leave
{
    [self confirmLeaveThen:^{
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

#pragma mark Navigation and search

- (void)scrollToOffset:(unsigned long long)offset
{
    if (_size == 0) return;
    if (offset >= _size) offset = _size - 1;
    NSInteger row = (NSInteger)(offset / _perRow);
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                          atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

- (void)goToOffset
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"跳转到偏移量"
        message:@"十六进制（0x1a2b）或十进制" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"0x0";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"前往" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
        NSString *t = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        unsigned long long off = 0;
        if (!WQHexParseOffset(t, &off)) {
            wqh_alert(self, @"偏移量无效", @"请输入完整的非负十进制值或以 0x 开头的十六进制值。");
            return;
        }
        if (_size == 0) {
            wqh_alert(self, @"偏移量不可用", @"文件为空，或大小仍在加载。");
            return;
        }
        if (off >= _size) {
            wqh_alert(self, @"偏移量超出范围", [NSString stringWithFormat:@"请输入 0x0 至 0x%llx 之间的偏移量。", _size - 1]);
            return;
        }
        [self scrollToOffset:off];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptFindHex:(BOOL)hex
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:hex ? @"查找十六进制字节" : @"查找文本"
        message:@"从屏幕顶部开始，在已保存的文件中向前搜索。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = hex ? @"de ad be ef" : @"text";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"查找" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
        NSString *t = a.textFields.firstObject.text ?: @"";
        if (!WQHexSearchInputWithinLimit(t)) {
            wqh_alert(self, @"搜索内容过大", @"搜索输入最多使用 1 MiB 的 UTF-8 文本。");
            return;
        }
        NSData *needle = hex ? WQParseHex(t, NO) : [t dataUsingEncoding:NSUTF8StringEncoding];
        if (needle.length == 0) { wqh_alert(self, @"没有要查找的内容", hex ? @"请输入十六进制字节，例如 de ad be ef。" : @"请输入一些文本。"); return; }
        BOOL sameNeedle = self->_lastSearchNeedle && [self->_lastSearchNeedle isEqualToData:needle];
        NSInteger topRow = NSIntegerMax;
        for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
            if (indexPath.section == 0) topRow = MIN(topRow, indexPath.row);
        }
        if (topRow == NSIntegerMax) topRow = 0;
        unsigned long long from = (sameNeedle && self->_matchLength && self->_matchOffset < ULLONG_MAX)
            ? self->_matchOffset + 1 : (unsigned long long)topRow * self->_perRow;
        if (!sameNeedle) self->_matchLength = 0;
        self->_lastSearchNeedle = [needle copy];
        [self search:needle from:from];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)search:(NSData *)needle from:(unsigned long long)from
{
    NSUInteger generation = ++_searchGeneration;
    _status = @"Searching…";
    [self updateBar];
    NSString *path = _path;
    unsigned long long size = _size;
    NSUInteger requestLength = kSearchChunk + needle.length - 1;
    dispatch_async(_queue, ^{
        unsigned long long found = ULLONG_MAX;
        NSString *error = nil;
        for (unsigned long long pos = from; pos < size && found == ULLONG_MAX; ) {
            NSUInteger length = (NSUInteger)MIN((unsigned long long)requestLength, size - pos);
            NSData *chunk = wq_read_range(path, pos, length, &error);
            if (!chunk || chunk.length < needle.length) break;
            NSRange r = [chunk rangeOfData:needle options:0 range:NSMakeRange(0, chunk.length)];
            if (r.location != NSNotFound) found = pos + r.location;
            if (size - pos <= kSearchChunk) break;
            pos += kSearchChunk;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_searchGeneration || !wqh_is_visible(self)) return;
            self->_status = nil;
            [self updateBar];
            if (found == ULLONG_MAX) {
                self->_matchLength = 0;
                [self.tableView reloadData];
                wqh_alert(self, @"未找到", error ?: [NSString stringWithFormat:@"在偏移量 0x%llx 之后没有匹配项。", from]);
                return;
            }
            self->_matchOffset = found;
            self->_matchLength = needle.length;
            [self.tableView reloadData];
            [self scrollToOffset:found];
        });
    });
}

@end
