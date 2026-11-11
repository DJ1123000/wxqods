//
//  WQPlistEditor.m
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import "WQPlistEditor.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQUI.h"
#import "WQPlistEditorSupport.h"

typedef NS_ENUM(NSInteger, WQPType) {
    WQPTypeString, WQPTypeInteger, WQPTypeReal, WQPTypeBoolean, WQPTypeDate, WQPTypeData,
    WQPTypeDictionary, WQPTypeArray, WQPTypeUID, WQPTypeUnknown,
};

static WQPType wqp_type(id v)
{
    if ([v isKindOfClass:NSString.class]) return WQPTypeString;
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return WQPTypeBoolean;
        return CFNumberIsFloatType((__bridge CFNumberRef)v) ? WQPTypeReal : WQPTypeInteger;
    }
    if ([v isKindOfClass:NSDate.class]) return WQPTypeDate;
    if ([v isKindOfClass:NSData.class]) return WQPTypeData;
    if ([v isKindOfClass:NSDictionary.class]) return WQPTypeDictionary;
    if ([v isKindOfClass:NSArray.class]) return WQPTypeArray;
    if (WQPlistIsKeyedArchiveUID(v)) return WQPTypeUID;
    return WQPTypeUnknown;
}

static NSString *wqp_type_name(WQPType t)
{
    switch (t) {
        case WQPTypeString: return @"字符串";
        case WQPTypeInteger: return @"数字";
        case WQPTypeReal: return @"实数";
        case WQPTypeBoolean: return @"布尔值";
        case WQPTypeDate: return @"日期";
        case WQPTypeData: return @"数据";
        case WQPTypeDictionary: return @"字典";
        case WQPTypeArray: return @"数组";
        case WQPTypeUID: return @"引用";
        case WQPTypeUnknown: return @"?";
    }
    return @"?";
}

static NSString *wqp_hex(NSData *data, NSUInteger max)
{
    const uint8_t *b = data.bytes;
    NSUInteger n = MIN(data.length, max);
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 3];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:i ? @" %02x" : @"%02x", b[i]];
    if (data.length > max) [s appendString:@" …"];
    return s;
}

static NSISO8601DateFormatter *wqp_dates(void)
{
    static NSISO8601DateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSISO8601DateFormatter new]; });
    return f;
}

static NSString *wqp_summary(id v)
{
    switch (wqp_type(v)) {
        case WQPTypeString: return WQPBoundedStringPreview(v);
        case WQPTypeInteger: case WQPTypeReal: return [v stringValue];
        case WQPTypeBoolean: return [v boolValue] ? @"是" : @"否";
        case WQPTypeDate: return [wqp_dates() stringFromDate:v];
        case WQPTypeData: return [NSString stringWithFormat:@"%lu 字节 · %@", (unsigned long)[v length], wqp_hex(v, 24)];
        case WQPTypeDictionary: return [NSString stringWithFormat:@"%lu 个键", (unsigned long)[v count]];
        case WQPTypeArray: return [NSString stringWithFormat:@"%lu 项", (unsigned long)[v count]];
        case WQPTypeUID: return @"键归档引用";
        case WQPTypeUnknown: return WQPBoundedStringPreview([v description]);
    }
    return @"";
}

static NSString *wqp_scalar_text(id value, WQPType t)
{
    if (t == WQPTypeData) return wqp_hex(value, WQPMaxDataBytes);
    if (t == WQPTypeDate) return [wqp_dates() stringFromDate:value];
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

static id wqp_default(WQPType t)
{
    switch (t) {
        case WQPTypeString: return @"";
        case WQPTypeInteger: return @0;
        case WQPTypeReal: return @0.0;
        case WQPTypeBoolean: return @NO;
        case WQPTypeDate: return NSDate.date;
        case WQPTypeData: return [NSData data];
        case WQPTypeDictionary: return [NSMutableDictionary dictionary];
        case WQPTypeArray: return [NSMutableArray array];
        case WQPTypeUID: return @"";
        case WQPTypeUnknown: return @"";
    }
    return @"";
}

static void wqp_alert(UIViewController *host, NSString *title, NSString *message)
{
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:a animated:YES completion:nil];
}

#pragma mark - Document

@interface WQPlistDocument : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) id root;
@property (nonatomic) NSPropertyListFormat format;
@property (nonatomic) BOOL readOnly;
@property (nonatomic, strong) WQEditState *edit;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *version;
@end

@implementation WQPlistDocument
@end

#pragma mark - Editor

@interface WQPlistEditorViewController ()
@property (nonatomic, strong) WQPlistDocument *doc;
@property (nonatomic, strong) id container;   // NSMutableDictionary or NSMutableArray
@property (nonatomic, copy) NSArray *keys;    // sorted keys (dictionary) or nil (array)
@property (nonatomic, copy) NSString *status; // loading / error text
@property (nonatomic) BOOL isRoot;
@end

@implementation WQPlistEditorViewController {
    NSArray *_sortedKeyCache;
    BOOL _keysDirty;
}

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _doc = [WQPlistDocument new];
        _doc.path = path;
        _doc.readOnly = readOnly;
        _doc.edit = [WQEditState new];
        _isRoot = YES;
        _status = @"正在加载…";
        self.title = path.lastPathComponent;
    }
    return self;
}

- (instancetype)initWithDocument:(WQPlistDocument *)doc container:(id)container title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _doc = doc;
        _container = container;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    __weak typeof(self) weakSelf = self;
    if (self.isRoot) {
        self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
        [self load];
    } else {
        self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) {
            if ([weakSelf blockWhileSaving]) return;
            [weakSelf.navigationController popViewControllerAnimated:YES];
        }];
    }
    [self updateBar];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)load
{
    NSString *path = self.doc.path;
    dispatch_async(wq_io_interactive(), ^{   // document load (read-only path)
        NSString *error = nil;
        NSDictionary *__unused before = wq_file_version(path);
        NSData *data = wq_read(path, WQPMaxSerializedBytes, &error);
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || ![before isEqualToDictionary:version])) {
            data = nil;
            error = @"文件在读取期间已更改。请重新打开。";
        }
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        NSError *parseError = nil;
        id root = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                  options:NSPropertyListMutableContainersAndLeaves
                                                                   format:&format error:&parseError] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.doc.version = version;
            if (!root) {
                self.status = data ? [NSString stringWithFormat:@"不是属性列表：%@", parseError.localizedDescription]
                                   : (wq_permission_hint(path, NO) ?: [NSString stringWithFormat:@"无法读取此文件：%@", error]);
            } else if (![root isKindOfClass:NSMutableDictionary.class] && ![root isKindOfClass:NSMutableArray.class]) {
                // A plist whose root is a single value: wrap it for display only.
                self.doc.format = format;
                self.doc.root = root;
                self.doc.readOnly = YES;
                self.container = [NSMutableArray arrayWithObject:root];
                self.status = nil;
            } else {
                if (wq_permission_hint(path, YES)) self.doc.readOnly = YES;   // readable, but only the owner may write
                if (!WQPlistFormatIsWritable(format)) self.doc.readOnly = YES; // OpenStep/unknown format
                self.doc.root = root;
                self.doc.format = format;
                self.container = root;
                self.status = nil;
            }
            [self refresh];
        });
    });
}

- (void)refresh
{
    if ([self.container isKindOfClass:NSDictionary.class]) {
        if (!_sortedKeyCache || _keysDirty) {
            _sortedKeyCache = [[self.container allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
            _keysDirty = NO;
        }
        self.keys = _sortedKeyCache;
    } else {
        self.keys = nil;
        _sortedKeyCache = nil;
        _keysDirty = NO;
    }
    [self updateBar];
    [self.tableView reloadData];
}

- (BOOL)isArray
{
    return [self.container isKindOfClass:NSArray.class];
}

- (void)updateBar
{
    NSMutableArray *items = [NSMutableArray array];
    if (!self.doc.readOnly && self.container) {
        UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:wq_primary_button_style()
                                                                target:self action:@selector(save)];
        save.enabled = self.doc.edit.dirty && !self.doc.edit.saving;
        [items addObject:save];
        UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                              target:self action:@selector(add)];
        add.enabled = !self.doc.edit.saving;
        [items addObject:add];
    }
    NSMutableArray *menu = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    if (self.isArray && !self.doc.readOnly && !self.doc.edit.saving && self.container) {
        [menu addObject:[UIAction actionWithTitle:self.tableView.editing ? @"完成排序" : @"重新排序"
                                            image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil
                                          handler:^(UIAction *__unused a) {
            [weakSelf.tableView setEditing:!weakSelf.tableView.editing animated:YES];
            [weakSelf updateBar];
        }]];
    }
    if (self.openAsText) [menu addObject:[UIAction actionWithTitle:@"以 XML 文本打开" image:[UIImage systemImageNamed:@"doc.plaintext"]
                                                         identifier:nil handler:^(UIAction *__unused a) { [weakSelf leaveThen:weakSelf.openAsText]; }]];
    if (self.openAsHex) [menu addObject:[UIAction actionWithTitle:@"在十六进制查看器中打开" image:[UIImage systemImageNamed:@"number"]
                                                        identifier:nil handler:^(UIAction *__unused a) { [weakSelf leaveThen:weakSelf.openAsHex]; }]];
    if (menu.count)
        [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                           menu:[UIMenu menuWithChildren:menu]]];
    self.navigationItem.rightBarButtonItems = items;
}

#pragma mark Leaving and saving

- (BOOL)wq_needsLeaveConfirmation
{
    // Ordinary dirty child navigation keeps the shared edits, but no editor
    // may leave while the shared document is being written.
    return self.doc.edit.saving || (self.isRoot && self.doc.edit.dirty);
}

- (void)leave
{
    [self leaveThen:nil];
}

- (BOOL)blockWhileSaving
{
    if (!self.doc.edit.saving) return NO;
    wqp_alert(self, @"正在保存", @"请等待当前保存完成后再离开或做更多更改。");
    return YES;
}

// Asks before throwing away unsaved changes, then pops to the folder and runs `then`.
- (void)leaveThen:(void (^)(void))then
{
    if ([self blockWhileSaving]) return;
    UINavigationController *nav = self.navigationController;
    NSUInteger rootIndex = [nav.viewControllers indexOfObjectPassingTest:^BOOL(UIViewController *vc, NSUInteger __unused i, BOOL *__unused stop) {
        return [vc isKindOfClass:WQPlistEditorViewController.class] && ((WQPlistEditorViewController *)vc).isRoot &&
               ((WQPlistEditorViewController *)vc).doc == self.doc;
    }];
    void (^go)(void) = ^{
        if (rootIndex != NSNotFound && rootIndex > 0)
            [nav popToViewController:nav.viewControllers[rootIndex - 1] animated:then == nil];
        if (then) then();
    };
    if (!self.doc.edit.dirty) { go(); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"放弃更改？"
        message:@"对此属性列表的编辑尚未保存。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        [self.doc.edit discard];
        go();
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// Home button: ask before throwing away unsaved changes.
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!self.doc.edit.dirty) { proceed(); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"放弃更改？"
        message:@"对此属性列表的编辑尚未保存。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        [self.doc.edit discard];
        proceed();
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)save
{
    if ([self blockWhileSaving] || self.doc.readOnly || !self.doc.edit.dirty) return;
    WQPlistDocument *doc = self.doc;
    if (!WQPlistFormatIsWritable(doc.format)) {
        wqp_alert(self, @"只读格式", @"此属性列表使用 OpenStep/未知格式，编辑器无法保存。请使用“以 XML 文本打开”并明确选择受支持的格式。");
        return;
    }
    if (!doc.version) {
        wqp_alert(self, @"无法安全保存", @"当前文件版本不可用。请重新打开文件后再保存。");
        return;
    }
    NSString *fmt = WQPlistFormatName(doc.format);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存更改？"
        message:[NSString stringWithFormat:@"%@ 将被原地覆盖（%@ 格式）。当前版本会先备份。",
                 doc.path, fmt]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused x) {
        NSUInteger savedRevision = [doc.edit beginSave];
        NSDictionary *expectedVersion = [doc.version copy];
        NSString *path = [doc.path copy];
        NSPropertyListFormat format = doc.format;
        id root = doc.root;
        UINavigationController *navigationController = self.navigationController;
        __weak WQPlistEditorViewController *weakSelf = self;
        [self refresh];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *serializationError = nil;
            NSString *writeError = nil;
            BOOL ok = NO;
            NSDictionary *savedVersion = nil;
            NSString *copyError = nil;
            id snapshot = WQPlistImmutableCopy(root, &copyError);
            NSData *data = snapshot ? [NSPropertyListSerialization dataWithPropertyList:snapshot
                                                                                     format:format
                                                                                    options:0
                                                                                      error:&serializationError] : nil;
            if (!snapshot) {
                writeError = copyError ?: @"The edited property list contains an unsupported value.";
            } else if (!data) {
                writeError = serializationError.localizedDescription ?: @"The edited property list is not valid.";
            } else if (!WQPSerializedDataWithinLimit(data)) {
                writeError = [NSString stringWithFormat:@"The serialized property list is too large (maximum %lu MiB).",
                              (unsigned long)(WQPMaxSerializedBytes / (1024 * 1024))];
            } else {
                NSError *validationError = nil;
                id check = [NSPropertyListSerialization propertyListWithData:data
                                                                        options:NSPropertyListImmutable
                                                                         format:NULL
                                                                          error:&validationError];
                if (!check) {
                    writeError = validationError.localizedDescription ?: @"The serialized property list could not be validated.";
                } else {
                    ok = wq_write_if_unchanged_get_version(path, data, expectedVersion, &savedVersion, &writeError);
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [doc.edit finishSave:ok revision:savedRevision];
                // Returned while the saved bytes were verified on the locked
                // descriptor; a later external change is rejected next save.
                if (ok) doc.version = savedVersion;

                WQPlistEditorViewController *origin = weakSelf;
                UINavigationController *nav = navigationController ?: origin.navigationController;
                WQPlistEditorViewController *visible = nil;
                for (UIViewController *controller in nav.viewControllers) {
                    if (![controller isKindOfClass:WQPlistEditorViewController.class]) continue;
                    WQPlistEditorViewController *editor = (WQPlistEditorViewController *)controller;
                    if (editor.doc != doc) continue;
                    [editor refresh];
                    if (controller == nav.visibleViewController) visible = editor;
                }
                if (!visible && origin.doc == doc) {
                    [origin refresh];
                    if (origin.viewIfLoaded.window) visible = origin;
                }
                if (!ok && visible.viewIfLoaded.window) {
                    NSString *hint = wq_permission_hint(path, YES);
                    wqp_alert(visible, @"保存失败", hint ?: writeError ?: @"未知错误");
                }
            });
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)changed
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    // Callers have already changed the data. Record it even during a save: the
    // newer revision keeps the document dirty when that save finishes. The
    // guard above also protects stale UI callbacks from changing readonly or
    // frozen documents.
    _keysDirty = YES;
    [self.doc.edit noteChange];
    [self refresh];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.status ? 0 : (NSInteger)[self.container count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.status) return self.status;
    if (!self.isRoot) return nil;
    NSString *fmt = WQPlistFormatName(self.doc.format);
    if (self.doc.readOnly) {
        NSString *reason = WQPlistFormatIsWritable(self.doc.format) ? @"只读" : @"只读 · 不支持写入";
        return [NSString stringWithFormat:@"%@ 属性列表 · %@", fmt, reason];
    }
    return [NSString stringWithFormat:@"%@ 属性列表。轻点值可编辑，滑动可删除或重命名，轻点 + 可添加。", fmt];
}

- (id)keyAt:(NSInteger)row
{
    return self.isArray ? @(row) : self.keys[(NSUInteger)row];
}

- (id)valueAt:(NSInteger)row
{
    return self.isArray ? self.container[(NSUInteger)row] : self.container[self.keys[(NSUInteger)row]];
}

- (void)setValue:(id)value at:(NSInteger)row
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    if (self.isArray) self.container[(NSUInteger)row] = value;
    else self.container[self.keys[(NSUInteger)row]] = value;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"plist"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"plist"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    id value = [self valueAt:indexPath.row];
    WQPType t = wqp_type(value);
    c.text = self.isArray ? [NSString stringWithFormat:@"项目 %ld", (long)indexPath.row] : [self keyAt:indexPath.row];
    c.secondaryText = [NSString stringWithFormat:@"%@ · %@", wqp_type_name(t), wqp_summary(value)];
    c.secondaryTextProperties.numberOfLines = 3;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    if (t == WQPTypeDictionary || t == WQPTypeArray) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (t == WQPTypeBoolean) {
        UISwitch *sw = [UISwitch new];
        sw.on = [value boolValue];
        sw.enabled = !self.doc.readOnly && !self.doc.edit.saving;
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(boolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)boolChanged:(UISwitch *)sw
{
    if (self.doc.readOnly || self.doc.edit.saving) {
        sw.on = [[self valueAt:sw.tag] boolValue];
        return;
    }
    [self setValue:@(sw.on) at:sw.tag];
    [self changed];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.doc.edit.saving) return;
    id value = [self valueAt:indexPath.row];
    WQPType t = wqp_type(value);
    NSString *name = self.isArray ? [NSString stringWithFormat:@"项目 %ld", (long)indexPath.row] : [self keyAt:indexPath.row];
    if (t == WQPTypeDictionary || t == WQPTypeArray) {
        WQPlistEditorViewController *child = [[WQPlistEditorViewController alloc] initWithDocument:self.doc container:value title:name];
        [self.navigationController pushViewController:child animated:YES];
        return;
    }
    if (t == WQPTypeUID) {
        wqp_alert(self, @"引用值", @"键归档引用在此编辑器中为只读。请通过其所属的键编辑归档数据。");
        return;
    }
    if (t == WQPTypeBoolean || self.doc.readOnly || self.doc.edit.saving) return;
    NSInteger row = indexPath.row;
    [self editValueOfType:t current:value title:name done:^(id newValue) {
        [self setValue:newValue at:row];
        [self changed];
    }];
}

// Asks for a scalar value of type `t`; `done` gets the parsed value.
- (void)editValueOfType:(WQPType)t current:(id)current title:(NSString *)title done:(void (^)(id value))done
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    if (t == WQPTypeUID) return;
    if (t == WQPTypeData && [current length] > WQPMaxDataBytes) {
        wqp_alert(self, @"太大，无法在此编辑", @"此编辑器无法编辑超过 4 KB 的数据。");
        return;
    }
    if (t == WQPTypeString && [current length] > WQPMaxStringInputCharacters) {
        wqp_alert(self, @"太大，无法在此编辑", @"此编辑器无法编辑超过 64 KB 的字符串。");
        return;
    }
    NSString *hint = nil;
    switch (t) {
        case WQPTypeInteger: hint = @"整数"; break;
        case WQPTypeReal: hint = @"数字"; break;
        case WQPTypeDate: hint = @"ISO 8601，例如 2026-11-09T15:00:00Z"; break;
        case WQPTypeData: hint = @"十六进制字节，例如 01 ab ff"; break;
        default: break;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                message:[wqp_type_name(t) stringByAppendingString:hint ? [@" · " stringByAppendingString:hint] : @""]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = wqp_scalar_text(current, t);
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
        if (t == WQPTypeInteger) f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        if (t == WQPTypeReal) f.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        id value = nil;
        if (t != WQPTypeData && !WQPStringInputWithinLimit(text)) {
            wqp_alert(self, @"值过大", @"此编辑器中标量值限制为 64 KB。");
            return;
        }
        if (t == WQPTypeData && !WQPDataInputWithinLimit(text)) {
            wqp_alert(self, @"值过大", @"此编辑器中十六进制输入限制为 16 KB。");
            return;
        }
        switch (t) {
            case WQPTypeString: value = text; break;
            case WQPTypeInteger: {
                NSScanner *sc = [NSScanner scannerWithString:text];
                long long n;
                if ([sc scanLongLong:&n] && sc.isAtEnd) value = @(n);
                break;
            }
            case WQPTypeReal: {
                NSScanner *sc = [NSScanner scannerWithString:text];
                double d;
                if ([sc scanDouble:&d] && sc.isAtEnd) value = @(d);
                break;
            }
            case WQPTypeDate: value = [wqp_dates() dateFromString:text]; break;
            case WQPTypeData: {
                NSData *data = WQParseHex(text, YES);
                if (data.length > WQPMaxDataBytes) {
                    wqp_alert(self, @"值过大", @"此编辑器中数据值限制为 4 KB。");
                    return;
                }
                value = data;
                break;
            }
            default: break;
        }
        if (!value) { wqp_alert(self, @"值无效", [NSString stringWithFormat:@"应为：%@", hint ?: wqp_type_name(t)]); return; }
        done(value);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Adding, deleting, renaming, moving

- (void)add
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"添加" message:@"新值的类型"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (WQPType t = WQPTypeString; t <= WQPTypeArray; t++) {
        [sheet addAction:[UIAlertAction actionWithTitle:wqp_type_name(t) style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
            [self addValueOfType:t];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.count > 1
        ? self.navigationItem.rightBarButtonItems[1] : self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addValueOfType:(WQPType)t
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    void (^insert)(NSString *key) = ^(NSString *key) {
        if (self.doc.readOnly || self.doc.edit.saving) return;
        id value = wqp_default(t);
        void (^put)(id) = ^(id v) {
            if (self.doc.readOnly || self.doc.edit.saving) return;
            if (self.isArray) {
                [self.container addObject:v];
            } else {
                if (!key.length) return;  // dictionary insertion always has a validated key
                NSMutableDictionary *dictionary = self.container;
                dictionary[key] = v;
            }
            [self changed];
        };
        if (t == WQPTypeDictionary || t == WQPTypeArray || t == WQPTypeBoolean) { put(value); return; }
        [self editValueOfType:t current:value title:key ?: @"新项目" done:put];
    };
    if (self.isArray) { insert(nil); return; }
    [self askKey:nil title:@"键" done:insert];
}

- (void)askKey:(NSString *)current title:(NSString *)title done:(void (^)(NSString *key))done
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = current;
        f.placeholder = @"键";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused x) {
        NSString *key = a.textFields.firstObject.text ?: @"";
        if (key.length == 0) return;
        if (![key isEqualToString:current] && self.container[key]) {
            wqp_alert(self, @"键已存在", [NSString stringWithFormat:@"已存在名为“%@”的键。", key]);
            return;
        }
        done(key);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.doc.readOnly || self.doc.edit.saving) return nil;
    NSInteger row = indexPath.row;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除"
        handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
        if (self.doc.readOnly || self.doc.edit.saving) { completion(NO); return; }
        if (self.isArray) [self.container removeObjectAtIndex:(NSUInteger)row];
        else [self.container removeObjectForKey:self.keys[(NSUInteger)row]];
        [self changed];
        completion(YES);
    }];
    if (self.isArray) return [UISwipeActionsConfiguration configurationWithActions:@[del]];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"重命名"
        handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
        if (self.doc.readOnly || self.doc.edit.saving) { completion(NO); return; }
        NSString *old = self.keys[(NSUInteger)row];
        [self askKey:old title:@"重命名键" done:^(NSString *key) {
            if (self.doc.readOnly || self.doc.edit.saving) return;
            if ([key isEqualToString:old]) return;
            id v = self.container[old];
            [self.container removeObjectForKey:old];
            self.container[key] = v;
            [self changed];
        }];
        completion(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, rename]];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return self.isArray && !self.doc.readOnly && !self.doc.edit.saving;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    if (self.doc.readOnly || self.doc.edit.saving) return;
    id v = self.container[(NSUInteger)from.row];
    [self.container removeObjectAtIndex:(NSUInteger)from.row];
    [self.container insertObject:v atIndex:(NSUInteger)to.row];
    [self.doc.edit noteChange];
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

@end
