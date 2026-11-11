//
//  main.m
//  WQ Files
//
//  Proof-of-concept file browser for iOS 27 that reaches other containers
//  through the worse_query sandbox escape by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//  This app is GPL-3.0-or-later as well (see LICENSE).
//

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQDir.h"
#import "WQApps.h"
#import "WQCache.h"
#import "WQCore.h"
#import "WQPlistEditor.h"
#import "WQPlistEditorSupport.h"
#import "WQHexViewer.h"
#import "WQSQLiteViewer.h"
#import "WQArchive.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/mount.h>

static BOOL wq_looks_like_uuid(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

static BOOL wq_regular_file_for_ui(NSString *path)
{
    struct stat st;
    if (!wq_stat(path, &st)) return NO;
    // Symbolic links are deliberately not followed: the file APIs use
    // O_NOFOLLOW and the UI must offer the same contract.
    return S_ISREG(st.st_mode);
}

#pragma mark - Item

@interface WQItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *bundleID;  // for the app icon
@property (nonatomic) BOOL isDir;
@property (nonatomic) BOOL isLink;
@property (nonatomic) BOOL isRegular;
@property (nonatomic) unsigned long long size;
@property (nonatomic) mode_t mode;
@property (nonatomic) uid_t uid;
@property (nonatomic, strong) NSDate *modified;
@property (nonatomic, strong) NSDate *created;
@end

@implementation WQItem
@end

#pragma mark - File viewer

typedef NS_ENUM(NSInteger, WQOpenMode) { WQOpenAuto, WQOpenPlist, WQOpenText, WQOpenHex, WQOpenSQLite, WQOpenMedia };
// Opens a file in the fitting viewer (Auto: chosen from its first bytes).
static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode);

typedef NS_ENUM(NSInteger, WQViewKind) { WQViewText, WQViewPlist, WQViewImage, WQViewHex };

static const NSUInteger kViewLimit = 4 * 1024 * 1024;
static const NSUInteger kHexLimit = 64 * 1024;

// Parsing and image creation happen on the I/O queue; the main thread only
// installs the prepared display.
@interface WQFileDisplay : NSObject
@property (nonatomic) BOOL truncated;
@property (nonatomic, strong) NSString *plistText;
@property (nonatomic) NSPropertyListFormat plistFormat;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSString *text;
@property (nonatomic, strong) NSString *hexText;
@end
@implementation WQFileDisplay
@end

static NSString *wq_file_hex_dump(NSData *data, BOOL truncated)
{
    NSUInteger len = MIN(data.length, kHexLimit);
    const uint8_t *b = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:len * 4];
    for (NSUInteger off = 0; off < len; off += 16) {
        [out appendFormat:@"%08lx  ", (unsigned long)off];
        NSMutableString *ascii = [NSMutableString new];
        for (NSUInteger i = 0; i < 16; i++) {
            if (off + i < len) {
                uint8_t c = b[off + i];
                [out appendFormat:@"%02x ", c];
                [ascii appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
            } else {
                [out appendString:@"   "];
            }
        }
        [out appendFormat:@" %@\n", ascii];
    }
    if (data.length > len || truncated) [out appendString:@"\n…（仅显示开头部分）\n"];
    return out;
}

@interface WQFileViewController : UIViewController <UITextViewDelegate, WQUnsavedEditing>
@property (nonatomic) BOOL readOnly;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation WQFileViewController {
    NSString *_path;
    UITextView *_textView;
    UIImageView *_imageView;
    UIBarButtonItem *_editButton;
    WQViewKind _kind;
    NSPropertyListFormat _plistFormat;
    BOOL _truncated;
    WQEditState *_editState;
    NSDictionary<NSString *, NSNumber *> *_version;
}


- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        _editState = [WQEditState new];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.editable = NO;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.alwaysBounceVertical = YES;
    _textView.delegate = self;
    [self.view addSubview:_textView];
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
    _imageView = [UIImageView new];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.hidden = YES;
    [self.view addSubview:_imageView];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    for (UIView *v in @[_textView, _imageView]) {
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:g.topAnchor],
            [v.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
            [v.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        ]];
    }
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self action:@selector(share:)];
    UIMenu *openAs = [UIMenu menuWithTitle:@"打开方式" children:@[
        [UIAction actionWithTitle:@"Plist 编辑器" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenPlist]; }],
        [UIAction actionWithTitle:@"十六进制查看器" image:[UIImage systemImageNamed:@"number"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenHex]; }],
        [UIAction actionWithTitle:@"SQLite 查看器" image:[UIImage systemImageNamed:@"tablecells"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenSQLite]; }],
        [UIAction actionWithTitle:@"媒体播放器" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenMedia]; }],
    ]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:openAs];
    self.navigationItem.rightBarButtonItems = @[share, more];
    _textView.text = @"正在加载…";
    [self load];
}

- (void)load
{
    NSString *path = _path;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        struct stat st;
        BOOL exists = wq_stat(path, &st);
        NSDictionary *__unused before = wq_file_version(path);
        NSData *data = wq_read(path, kViewLimit + 1, &error);
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || !version || ![before isEqualToDictionary:version])) {
            data = nil;
            error = version ? @"文件在读取期间已更改。请重新打开。"
                            : @"Could not establish a stable file version. Open it again.";
        }
        WQFileDisplay *display = nil;
        if (data) {
            display = [WQFileDisplay new];
            display.truncated = data.length > kViewLimit;
            NSData *view = display.truncated ? [data subdataWithRange:NSMakeRange(0, kViewLimit)] : data;
            if (!display.truncated) {
                NSPropertyListFormat format = 0;
                id plist = [NSPropertyListSerialization propertyListWithData:view options:0 format:&format error:nil];
                if (plist) {
                    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                            format:NSPropertyListXMLFormat_v1_0
                                                                           options:0 error:nil];
                    NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : nil;
                    if (text) {
                        display.plistFormat = format;
                        display.plistText = text;
                    }
                }
            }
            if (!display.plistText) {
                display.image = [UIImage imageWithData:view];
                if (!display.image) {
                    NSString *text = [[NSString alloc] initWithData:view encoding:NSUTF8StringEncoding];
                    if (text && ![text containsString:@"\0"]) display.text = text;
                    else display.hexText = wq_file_hex_dump(view, display.truncated);
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_version = version;
            if (!display) {
                NSString *hint = wq_permission_hint(path, NO);
                self->_textView.text = [NSString stringWithFormat:@"无法读取此文件。\n\n%@", hint ?: error];
                return;
            }
            NSString *info = exists
                ? [NSString stringWithFormat:@"%@ · mode %o · uid %u", wq_size_text((unsigned long long)st.st_size),
                   st.st_mode & 07777, st.st_uid]
                : @"";
            self.navigationItem.prompt = info.length ? info : nil;
            if (wq_permission_hint(path, YES)) self->_readOnly = YES;   // only the owner may write it
            [self showDisplay:display];
        });
    });
}

- (void)showDisplay:(WQFileDisplay *)display
{
    _truncated = display.truncated;
    if (display.plistText) {
        _kind = WQViewPlist;
        _plistFormat = display.plistFormat;
        _textView.text = display.plistText;
        if (!WQPlistFormatIsWritable(display.plistFormat)) {
            _readOnly = YES;
            NSString *prompt = self.navigationItem.prompt;
            NSString *reason = [NSString stringWithFormat:@"%@ · read only", WQPlistFormatName(display.plistFormat)];
            self.navigationItem.prompt = prompt.length ? [prompt stringByAppendingFormat:@" · %@", reason] : reason;
        }
        if (!_readOnly) [self enableEditing];
        return;
    }
    if (display.image) {
        _kind = WQViewImage;
        _imageView.image = display.image;
        _imageView.hidden = NO;
        _textView.hidden = YES;
        return;
    }
    if (display.text) {
        _kind = WQViewText;
        _textView.text = display.text;
        if (!_truncated && !_readOnly) [self enableEditing];
        return;
    }
    _kind = WQViewHex;
    _textView.text = display.hexText ?: @"";
}

- (void)updateEditButton
{
    _editButton.title = _textView.editable ? @"保存" : @"编辑";
    _editButton.style = _textView.editable ? wq_primary_button_style() : UIBarButtonItemStylePlain;
    _editButton.enabled = !_editState.saving;
}

- (void)enableEditing
{
    if (_editButton) return;
    _editButton = [[UIBarButtonItem alloc] initWithTitle:@"编辑" style:UIBarButtonItemStylePlain
                                                  target:self action:@selector(toggleEdit:)];
    NSArray *items = self.navigationItem.rightBarButtonItems;
    self.navigationItem.rightBarButtonItems = [items arrayByAddingObject:_editButton];
}

- (void)textViewDidChange:(UITextView *)textView
{
    if (_editState.saving) return;
    [_editState noteChange];
}

- (BOOL)blockWhileSaving
{
    if (!_editState.saving) return NO;
    wq_alert(self, @"正在保存", @"请等待当前保存完成后再离开或做更多更改。");
    return YES;
}

- (BOOL)wq_needsLeaveConfirmation
{
    return _editState.dirty || _editState.saving;
}

- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_editState.dirty) { proceed(); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"放弃更改？"
        message:@"文本更改尚未保存。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self->_editState discard];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        proceed();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)leave
{
    [self confirmLeaveThen:^{ [self.navigationController popViewControllerAnimated:YES]; }];
}

- (void)toggleEdit:(UIBarButtonItem *)sender
{
    if ([self blockWhileSaving]) return;
    if (!_textView.editable) {
        _textView.editable = YES;
        [self updateEditButton];
        [_textView becomeFirstResponder];
        return;
    }
    if (!_editState.dirty) {
        _textView.editable = NO;
        [_textView resignFirstResponder];
        [self updateEditButton];
        return;
    }
    if (!_version) {
        wq_alert(self, @"无法保存", @"此文件没有已验证的版本快照。请重新打开后再保存。");
        return;
    }
    NSData *newData = nil;
    if (_kind == WQViewPlist) {
        NSData *xml = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id plist = xml ? [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:&error] : nil;
        if (!plist) {
            wq_alert(self, @"不是有效的属性列表", error.localizedDescription ?: @"请检查 XML。");
            return;
        }
        newData = [NSPropertyListSerialization dataWithPropertyList:plist format:_plistFormat options:0 error:&error];
        if (!newData) {
            wq_alert(self, @"无法编码", error.localizedDescription ?: @"");
            return;
        }
    } else {
        newData = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!newData) {
        wq_alert(self, @"无法编码", @"文本无法编码为 UTF-8。");
        return;
    }
    NSString *message = [NSString stringWithFormat:@"%@ 将被原地覆盖。当前版本会先备份到“备份”。", _path];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"保存更改？" message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        NSUInteger savedRevision = [self->_editState beginSave];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        NSString *path = self->_path;
        NSDictionary *expectedVersion = [self->_version copy];
        dispatch_async(wq_io(), ^{
            NSString *error = nil;
            NSDictionary *newVersion = nil;
            BOOL ok = wq_write_if_unchanged_get_version(path, newData, expectedVersion, &newVersion, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_editState finishSave:ok revision:savedRevision];
                if (ok) self->_version = newVersion;
                self->_textView.editable = self->_editState.dirty;
                [self updateEditButton];
                if (!ok) wq_alert(self, @"保存失败", error ?: wq_permission_hint(path, YES) ?: @"未知错误");
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender
{
    wq_share(self, _path, nil);
}

- (void)reopenAs:(WQOpenMode)mode
{
    [self confirmLeaveThen:^{
        UINavigationController *nav = self.navigationController;
        NSString *path = self->_path;
        BOOL readOnly = self->_readOnly;
        [nav popViewControllerAnimated:NO];
        wq_open_file(nav, path, readOnly, mode);
    }];
}

@end

#pragma mark - Choosing a viewer

static WQOpenMode wq_sniff(NSData *head)
{
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n >= 7 && memcmp(b, "bplist0", 7) == 0) return WQOpenPlist;
    if (wq_is_sqlite_header(head)) return WQOpenSQLite;
    if ((n >= 8 && memcmp(b, "\x89PNG", 4) == 0) || (n >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
        (n >= 4 && memcmp(b, "GIF8", 4) == 0) || (n >= 12 && memcmp(b + 4, "ftyp", 4) == 0))
        return WQOpenText;   // images: the file viewer renders them
    if (n == 0) return WQOpenText;
    if (memchr(b, 0, n)) return WQOpenHex;
    NSString *text = nil;
    for (NSUInteger cut = 0; cut < 4 && !text && cut < n; cut++)   // the sample may end mid-character
        text = [[NSString alloc] initWithBytes:b length:n - cut encoding:NSUTF8StringEncoding];
    if (!text) return WQOpenHex;
    if ([text containsString:@"<plist"] || [text containsString:@"<!DOCTYPE plist"]) return WQOpenPlist;
    return WQOpenText;
}

static NSUInteger wq_open_generation;

// Audio and video by extension (the first bytes of MP4/MOV look like HEIC images).
static BOOL wq_is_media_name(NSString *name)
{
    static NSSet<NSString *> *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[@"mp3", @"m4a", @"m4b", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac", @"alac",
                                     @"mp4", @"m4v", @"mov", @"3gp", @"3g2", @"m3u8"]];
    });
    return [exts containsObject:name.pathExtension.lowercaseString];
}

// The system player decodes in a separate process that can't read other
// apps' folders, so the file is copied to WQ Files' temporary folder first
// (the previous copy is removed).
static void wq_open_media(UINavigationController *nav, NSString *path, BOOL (^stillWanted)(void))
{
    UIViewController *host = nav.topViewController;
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"正在准备…" message:path.lastPathComponent
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [host presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wq-media"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:dir error:nil];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *local = [dir stringByAppendingPathComponent:path.lastPathComponent];
        NSString *error = nil;
        BOOL ok = wq_copy_to_local(path, local, &error);
        wq_log(@"media: %@ -> %@", path, ok ? @"OK" : error);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^show)(void) = ^{
                if (!ok) { wq_alert(host, @"无法播放", error ?: @"无法读取此文件。"); return; }
                if (!stillWanted()) return;
                [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
                AVPlayerViewController *player = [AVPlayerViewController new];
                player.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:local]];
                player.title = path.lastPathComponent;
                [nav pushViewController:player animated:YES];
                [player.player play];
            };
            if (host.presentedViewController == hud) [host dismissViewControllerAnimated:YES completion:show];
            else show();
        });
    });
}

static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode)
{
    if (!nav || !path.length) return;
    // All calls originate on the main thread. A newer explicit or automatic
    // open invalidates older sniff requests, and leaving the originating screen
    // also prevents a late push.
    NSUInteger request = ++wq_open_generation;
    UIViewController *origin = nav.topViewController;
    void (^push)(WQOpenMode) = ^(WQOpenMode m) {
        if (request != wq_open_generation || nav.topViewController != origin) return;
        if (m == WQOpenMedia) {
            wq_open_media(nav, path, ^BOOL { return request == wq_open_generation && nav.topViewController == origin; });
            return;
        }
        UIViewController *vc;
        if (m == WQOpenPlist) {
            WQPlistEditorViewController *editor = [[WQPlistEditorViewController alloc] initWithPath:path readOnly:readOnly];
            __weak UINavigationController *weakNav = nav;
            editor.openAsText = ^{ wq_open_file(weakNav, path, readOnly, WQOpenText); };
            editor.openAsHex = ^{ wq_open_file(weakNav, path, readOnly, WQOpenHex); };
            vc = editor;
        } else if (m == WQOpenHex) {
            vc = [[WQHexViewController alloc] initWithPath:path readOnly:readOnly];
        } else if (m == WQOpenSQLite) {
            vc = [[WQSQLiteViewController alloc] initWithPath:path];
        } else {
            WQFileViewController *file = [[WQFileViewController alloc] initWithPath:path];
            file.readOnly = readOnly;
            vc = file;
        }
        [nav pushViewController:vc animated:YES];
    };
    if (!wq_regular_file_for_ui(path)) {
        UIViewController *host = nav.topViewController;
        struct stat st;
        BOOL link = wq_stat(path, &st) && S_ISLNK(st.st_mode);
        if (host) wq_alert(host, link ? @"符号链接" : @"无法打开此项目",
                           link ? @"WQ Files 在查看、分享或编辑时不跟随符号链接。"
                                : @"只能查看常规文件。");
        return;
    }
    if (mode == WQOpenAuto && wq_is_media_name(path)) mode = WQOpenMedia;
    if (mode != WQOpenAuto) { push(mode); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *head = wq_permission_hint(path, NO) ? nil : wq_read_range(path, 0, 4096, NULL);
        WQOpenMode m = head ? wq_sniff(head) : WQOpenText;   // unreadable: the file viewer shows why
        dispatch_async(dispatch_get_main_queue(), ^{ push(m); });
    });
}

#pragma mark - Folder

static NSString *wq_folder_date_text(NSDate *date)
{
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.locale = NSLocale.autoupdatingCurrentLocale;
    });
    return date ? [formatter stringFromDate:date] : @"";
}

#pragma mark - Folder sorting

// One sort order for all folders, remembered. Each key starts in its natural
// direction (A–Z, newest first, largest first); picking it again reverses it.
typedef NS_ENUM(NSInteger, WQSortKey) { WQSortName, WQSortModified, WQSortCreated, WQSortSize };
static NSString *const kWQSortKeyPref = @"WQFolderSortKey";
static NSString *const kWQSortAscendingPref = @"WQFolderSortAscending";
static NSString *const kWQFoldersFirstPref = @"WQFolderSortFoldersFirst";

static WQSortKey wq_sort_key(void)
{
    NSInteger key = [NSUserDefaults.standardUserDefaults integerForKey:kWQSortKeyPref];
    return key >= WQSortName && key <= WQSortSize ? (WQSortKey)key : WQSortName;
}

static BOOL wq_sort_ascending(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kWQSortAscendingPref];
    return value ? [value boolValue] : YES;
}

static BOOL wq_folders_first(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kWQFoldersFirstPref];
    return value ? [value boolValue] : YES;
}

static void wq_choose_sort(WQSortKey key)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL ascending = key == wq_sort_key() ? !wq_sort_ascending() : key == WQSortName;
    [d setInteger:key forKey:kWQSortKeyPref];
    [d setBool:ascending forKey:kWQSortAscendingPref];
}

static NSString *wq_sort_direction_text(WQSortKey key, BOOL ascending)
{
    switch (key) {
        case WQSortName: return ascending ? @"A–Z" : @"Z–A";
        case WQSortSize: return ascending ? @"从小到大" : @"从大到小";
        default: return ascending ? @"从旧到新" : @"从新到旧";
    }
}

static NSArray<WQItem *> *wq_sorted_items(NSArray<WQItem *> *items)
{
    WQSortKey key = wq_sort_key();
    BOOL ascending = wq_sort_ascending(), foldersFirst = wq_folders_first();
    return [items sortedArrayUsingComparator:^NSComparisonResult(WQItem *a, WQItem *b) {
        if (foldersFirst && a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = NSOrderedSame;
        switch (key) {
            case WQSortName: break;
            case WQSortModified: r = [(a.modified ?: NSDate.distantPast) compare:(b.modified ?: NSDate.distantPast)]; break;
            case WQSortCreated: r = [(a.created ?: NSDate.distantPast) compare:(b.created ?: NSDate.distantPast)]; break;
            case WQSortSize: r = a.size < b.size ? NSOrderedAscending : a.size > b.size ? NSOrderedDescending : NSOrderedSame; break;
        }
        NSComparisonResult byName = [(a.label ?: a.name ?: @"") localizedStandardCompare:(b.label ?: b.name ?: @"")];
        if (key == WQSortName) r = byName;
        if (r == NSOrderedSame) return byName;
        return ascending ? r : (NSComparisonResult)-r;
    }];
}

// Sidebar letter for an entry: its first letter without accents, "#" for the rest.
static NSString *wq_index_letter(NSString *name)
{
    if (!name.length) return @"#";
    NSString *first = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
                       stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil].uppercaseString;
    unichar c = first.length ? [first characterAtIndex:0] : 0;
    return (c >= 'A' && c <= 'Z') ? [NSString stringWithCharacters:&c length:1] : @"#";
}

// Items picked with Move, waiting for "Move Here" in another folder.
static NSArray<NSString *> *gWQMovePaths;
static NSString *const kWQMoveChanged = @"WQMoveChanged";

static void wq_set_move_paths(NSArray<NSString *> *paths)
{
    gWQMovePaths = paths.count ? [paths copy] : nil;
    [NSNotificationCenter.defaultCenter postNotificationName:kWQMoveChanged object:nil];
}

// ZIP reading and writing through WQAccess, so other apps' files work too.
static WQArchiveIO *wq_app_archive_io(void)
{
    WQArchiveIO *io = [WQArchiveIO new];
    io.stat = ^BOOL(NSString *path, struct stat *st) { return wq_stat(path, st); };
    io.list = ^NSArray<NSString *> *(NSString *dir) { return wq_list(dir, NULL); };
    io.openRead = ^int(NSString *path) { return wq_open_for_reading(path); };
    return io;
}

@interface WQDirViewController ()
- (BOOL)wq_wantsToolbar;
@end

@implementation WQDirViewController {
    NSString *_path;
    NSArray<WQItem *> *_all;     // everything in the folder
    NSArray<WQItem *> *_items;   // what the search lets through (shown)
    NSString *_query;
    UILabel *_pathLabel;
    UIView *_headerBox;
    NSString *_scanStatus;
    CGFloat _headerWidth;
    NSString *_error;
    BOOL _labels;
    BOOL _backupManager;
    BOOL _backupStorage;
    BOOL _selectingBackups;
    NSMutableSet<NSString *> *_selectedBackups;
    UIBarButtonItem *_selectItem;
    UIBarButtonItem *_menuItem;
    UIBarButtonItem *_doneItem;
    UIBarButtonItem *_deleteItem;
    UIBarButtonItem *_allItem;
    NSString *_baseTitle;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanInFlight;
    BOOL _scanNeedsRefresh;
    NSTimeInterval _lastReloadFinished;
    NSArray<NSString *> *_indexTitles;          // sidebar letters, when sorted by name
    NSDictionary<NSString *, NSNumber *> *_indexRows;   // letter -> first row
    BOOL _selectingFiles;
    BOOL _importingFolder;
    NSMutableOrderedSet<NSString *> *_selectedFiles;
    UIBarButtonItem *_fileSelectItem;
    UIBarButtonItem *_fileDoneItem;
    UIBarButtonItem *_fileAllItem;
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        self.title = title ?: (path.lastPathComponent.length ? path.lastPathComponent : @"/");
        _baseTitle = self.title;
        _selectedBackups = [NSMutableSet new];
        _selectedFiles = [NSMutableOrderedSet new];
        // Container parents: show bundle/group identifiers instead of UUIDs.
        NSString *parent = path.lastPathComponent;
        _labels = [@[@"Application", @"AppGroup", @"PluginKitPlugin", @"InternalDaemon", @"System"] containsObject:parent];
        NSString *appBackups = wq_app_backup_root();
        NSString *fileBackups = wq_backup_root();
        _backupManager = appBackups.length &&
            ([_path isEqualToString:appBackups] || [_path hasPrefix:[appBackups stringByAppendingString:@"/"]]);
        _backupStorage = _backupManager ||
            (fileBackups.length && ([_path isEqualToString:fileBackups] || [_path hasPrefix:[fileBackups stringByAppendingString:@"/"]]));
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    __weak typeof(self) weakSelf = self;
    NSString *path = _path;
    NSMutableArray<UIMenuElement *> *menuItems = [NSMutableArray new];
    if (!self.readOnly && !_backupStorage) {
        [menuItems addObject:[UIAction actionWithTitle:@"新建文件夹" image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptNewFolder]; }]];
        [menuItems addObject:[UIAction actionWithTitle:@"导入文件" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importFile]; }]];
        [menuItems addObject:[UIAction actionWithTitle:@"导入文件夹" image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importFolder]; }]];
    }
    [menuItems addObject:[UIAction actionWithTitle:@"复制路径" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                          handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = path; }]];
    // Built when the menu opens, so the checkmarks show the current order.
    [menuItems addObject:[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        WQSortKey current = wq_sort_key();
        BOOL ascending = wq_sort_ascending();
        NSMutableArray *sortActions = [NSMutableArray new];
        NSArray *titles = @[@"名称", @"修改日期", @"创建日期", @"大小"];
        for (NSInteger key = WQSortName; key <= WQSortSize; key++) {
            UIAction *action = [UIAction actionWithTitle:titles[(NSUInteger)key] image:nil identifier:nil handler:^(UIAction *__unused a) {
                wq_choose_sort((WQSortKey)key);
                [weakSelf resortAfterChange];
            }];
            if (key == current) {
                action.state = UIMenuElementStateOn;
                action.subtitle = wq_sort_direction_text((WQSortKey)key, ascending);
            }
            [sortActions addObject:action];
        }
        UIAction *folders = [UIAction actionWithTitle:@"文件夹置顶" image:nil identifier:nil handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setBool:!wq_folders_first() forKey:kWQFoldersFirstPref];
            [weakSelf resortAfterChange];
        }];
        folders.state = wq_folders_first() ? UIMenuElementStateOn : UIMenuElementStateOff;
        UIMenu *order = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[folders]];
        UIMenu *sort = [UIMenu menuWithTitle:@"排序方式" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0
                                    children:[sortActions arrayByAddingObject:order]];
        sort.subtitle = [NSString stringWithFormat:@"%@, %@", titles[(NSUInteger)current], wq_sort_direction_text(current, ascending)];
        completion(@[sort]);
    }]];
    _menuItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                 menu:[UIMenu menuWithChildren:menuItems]];
    if (_backupStorage) {
        _selectItem = [[UIBarButtonItem alloc] initWithTitle:@"选择" style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(enterBackupSelection)];
        _selectItem.enabled = NO;
    } else if ([self canEditHere]) {
        _fileSelectItem = [[UIBarButtonItem alloc] initWithTitle:@"选择" style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(enterFileSelection)];
    }
    [self restoreRightItems];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateToolbar)
                                               name:kWQMoveChanged object:nil];
    [self updateToolbar];
    [self updateHeader];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = _labels ? @"搜索名称和 Bundle ID" : @"搜索此文件夹";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateToolbar];
    if (_scanInFlight) return;
    NSTimeInterval age = NSDate.date.timeIntervalSinceReferenceDate - _lastReloadFinished;
    if (_scanNeedsRefresh || _lastReloadFinished <= 0 || age > 2.0) [self reload];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (_selectingBackups) [self exitBackupSelection];
    if (_selectingFiles) [self exitFileSelection];
    if (_scanInFlight) {
        _scanNeedsRefresh = YES;
        [_scanCancellation cancel];
    }
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.presentedViewController && self.navigationController.topViewController != self) {
        wq_share_cancel(self);
    }
}

// Device strip, then the full path in normal-size text that wraps at the
// slashes (the navigation bar's prompt shrank it until unreadable). Tap to copy.
- (void)updateHeader
{
    CGFloat width = self.tableView.bounds.size.width ?: self.view.bounds.size.width;
    if (!_pathLabel) {
        _pathLabel = [UILabel new];
        _pathLabel.numberOfLines = 0;
        _pathLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _pathLabel.textColor = UIColor.secondaryLabelColor;
        _pathLabel.userInteractionEnabled = YES;
        [_pathLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPath)]];
    }
    if (!_headerBox) {
        _headerBox = wq_device_header(width);
        [_headerBox addSubview:_pathLabel];
        self.tableView.tableHeaderView = _headerBox;
    }
    // Zero-width spaces after each slash let lines break between components.
    NSString *breakable = [_path stringByReplacingOccurrencesOfString:@"/" withString:@"/\u200B"];
    _pathLabel.text = _scanStatus ? [NSString stringWithFormat:@"%@\n%@", breakable, _scanStatus] : breakable;
    CGFloat side = 16, top = 42;
    CGSize fit = [_pathLabel sizeThatFits:CGSizeMake(width - 2 * side, CGFLOAT_MAX)];
    CGFloat height = top + ceil(fit.height) + 10;
    CGFloat oldHeight = _headerBox.frame.size.height;
    _headerBox.frame = CGRectMake(0, 0, width, height);
    _pathLabel.frame = CGRectMake(side, top, width - 2 * side, ceil(fit.height));
    _headerWidth = width;
    if (fabs(height - oldHeight) > 0.5) self.tableView.tableHeaderView = _headerBox;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (fabs(self.tableView.bounds.size.width - _headerWidth) > 0.5) [self updateHeader];
}

- (void)copyPath
{
    UIPasteboard.generalPasteboard.string = _path;
    _scanStatus = @"路径已复制";
    [self updateHeader];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_scanStatus isEqualToString:@"路径已复制"]) { self->_scanStatus = nil; [self updateHeader]; }
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _query = q.length ? q : nil;
    [self applyFilter];
    [self.tableView reloadData];
}

// App name, bundle or group ID, or file name; case and accents ignored.
- (void)applyFilter
{
    NSArray<WQItem *> *shown = _all ?: @[];
    if (_query) {
        NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
        NSString *q = _query;
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQItem *item, NSDictionary *__unused b) {
            for (NSString *field in @[item.label ?: @"", item.name ?: @"", item.bundleID ?: @""])
                if ([field rangeOfString:q options:opts].location != NSNotFound) return YES;
            return NO;
        }]];
    }
    _items = wq_sorted_items(shown);
    // Alphabet sidebar: only for longer lists sorted by name.
    NSMutableArray *titles = [NSMutableArray new];
    NSMutableDictionary *rows = [NSMutableDictionary new];
    if (wq_sort_key() == WQSortName && _items.count >= 25) {
        [_items enumerateObjectsUsingBlock:^(WQItem *item, NSUInteger row, BOOL *__unused stop) {
            NSString *letter = wq_index_letter(item.label ?: item.name);
            if (!rows[letter]) { rows[letter] = @(row); [titles addObject:letter]; }
        }];
    }
    _indexTitles = titles.count > 1 ? titles : nil;
    _indexRows = rows;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return _selectingBackups || _selectingFiles || _error ? nil : _indexTitles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index
{
    NSNumber *row = _indexRows[title];
    if (row && row.unsignedIntegerValue < _items.count)
        [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:0]
                         atScrollPosition:UITableViewScrollPositionTop animated:NO];
    return -1;   // already scrolled to the row; the list has one section
}

- (void)resortAfterChange
{
    [self applyFilter];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

#pragma mark Backup multi-selection

- (NSArray<NSString *> *)backupUnitPathsInItems
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    for (WQItem *item in _items)
        if (wq_backup_unit_deletable(item.path)) [paths addObject:item.path];
    return paths;
}

- (void)updateBackupSelectionAvailability
{
    _selectItem.enabled = !_selectingBackups && [self backupUnitPathsInItems].count > 0;
}

- (void)updateBackupSelectionBar
{
    _deleteItem.enabled = _selectedBackups.count > 0;
    _allItem.enabled = _selectedBackups.count < [self backupUnitPathsInItems].count;
}

- (void)enterBackupSelection
{
    if ([self backupUnitPathsInItems].count == 0) {
        wq_alert(self, @"没有可选项", @"此处只能选择完整的备份文件夹。");
        return;
    }
    _selectingBackups = YES;
    [_selectedBackups removeAllObjects];
    if (!_doneItem) {
        _doneItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleProminent
                                                       target:self action:@selector(exitBackupSelection)];
        _deleteItem = [[UIBarButtonItem alloc] initWithTitle:@"删除" style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(deleteSelectedBackups)];
        _deleteItem.tintColor = UIColor.systemRedColor;
        _allItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]
                                                     style:UIBarButtonItemStylePlain
                                                    target:self action:@selector(selectAllBackups)];
        _allItem.accessibilityLabel = @"全选";
    }
    self.refreshControl.enabled = NO;
    self.tableView.allowsMultipleSelection = YES;
    self.title = @"选择备份";
    self.navigationItem.rightBarButtonItems = @[_allItem, _deleteItem, _doneItem];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)exitBackupSelection
{
    if (!_selectingBackups) return;
    _selectingBackups = NO;
    [_selectedBackups removeAllObjects];
    self.tableView.allowsMultipleSelection = NO;
    self.refreshControl.enabled = YES;
    self.title = _baseTitle;
    [self restoreRightItems];
    [self.tableView reloadData];
    [self updateBackupSelectionAvailability];
}

- (void)selectAllBackups
{
    NSArray<NSString *> *paths = [self backupUnitPathsInItems];
    [_selectedBackups addObjectsFromArray:paths];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)deleteSelectedBackups
{
    NSArray<NSString *> *paths = [_selectedBackups.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (paths.count == 0) return;
    NSString *message = [NSString stringWithFormat:
        @"这将永久删除 %lu 个完整备份及其中的全部内容。此操作无法撤销。",
        (unsigned long)paths.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除备份？"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *__unused a) {
        [self exitBackupSelection];
        [self runIO:^BOOL(NSString **error) {
            NSString *first = nil;
            for (NSString *path in paths) {
                NSString *failure = nil;
                if (!wq_delete_backup(path, &failure) && first == nil)
                    first = failure ?: @"无法删除备份。";
            }
            if (first) {
                if (error) *error = [NSString stringWithFormat:@"%@ 某些选定的备份可能仍然存在。", first];
                return NO;
            }
            return YES;
        } failure:@"无法删除备份"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark File selection, Move, Compress, Extract

// Ordinary folders where files may be created, moved and deleted: not
// read-only areas, not backup storage, not the container lists themselves.
- (BOOL)canEditHere
{
    return !self.readOnly && !_backupStorage && !_labels;
}

- (void)restoreRightItems
{
    if (_backupStorage && _selectItem) self.navigationItem.rightBarButtonItems = @[_selectItem, _menuItem];
    else if (_fileSelectItem) self.navigationItem.rightBarButtonItems = @[_fileSelectItem, _menuItem];
    else self.navigationItem.rightBarButtonItems = @[_menuItem];
}

- (BOOL)wq_wantsToolbar
{
    return _selectingFiles || gWQMovePaths.count > 0;
}

- (BOOL)canMoveHere
{
    if (![self canEditHere] || _error || !gWQMovePaths.count) return NO;
    for (NSString *path in gWQMovePaths) {
        if ([path.stringByDeletingLastPathComponent isEqualToString:_path]) return NO;
        if ([_path isEqualToString:path] || [_path hasPrefix:[path stringByAppendingString:@"/"]]) return NO;
    }
    return YES;
}

- (void)updateToolbar
{
    _fileSelectItem.enabled = !_error && _all.count > 0;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    if (_selectingFiles) {
        BOOL any = _selectedFiles.count > 0;
        UIBarButtonItem *move = [[UIBarButtonItem alloc] initWithTitle:@"移动" style:UIBarButtonItemStylePlain
                                                                target:self action:@selector(moveSelectedFiles)];
        UIBarButtonItem *zip = [[UIBarButtonItem alloc] initWithTitle:@"压缩" style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(compressSelectedFiles)];
        UIBarButtonItem *del = [[UIBarButtonItem alloc] initWithTitle:@"删除" style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(deleteSelectedFiles)];
        del.tintColor = UIColor.systemRedColor;
        move.enabled = zip.enabled = del.enabled = any;
        self.toolbarItems = @[move, flex, zip, flex, del];
    } else if (gWQMovePaths.count) {
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                                                  target:self action:@selector(cancelMove)];
        UILabel *label = [UILabel new];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        label.textColor = UIColor.secondaryLabelColor;
        label.text = gWQMovePaths.count == 1
            ? [NSString stringWithFormat:@"正在移动“%@”", gWQMovePaths.firstObject.lastPathComponent]
            : [NSString stringWithFormat:@"正在移动 %lu 个项目", (unsigned long)gWQMovePaths.count];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [label sizeToFit];
        CGRect frame = label.frame;
        frame.size.width = MIN(frame.size.width, 180);
        label.frame = frame;
        UIBarButtonItem *info = [[UIBarButtonItem alloc] initWithCustomView:label];
        UIBarButtonItem *here = [[UIBarButtonItem alloc] initWithTitle:@"移到此处" style:UIBarButtonItemStyleProminent
                                                                target:self action:@selector(moveHere)];
        here.enabled = [self canMoveHere];
        self.toolbarItems = @[cancel, flex, info, flex, here];
    } else {
        self.toolbarItems = nil;
    }
    if (self.navigationController.topViewController == self)
        [self.navigationController setToolbarHidden:![self wq_wantsToolbar] animated:YES];
}

- (void)updateFileSelectionTitle
{
    self.title = _selectedFiles.count
        ? [NSString stringWithFormat:@"%lu Selected", (unsigned long)_selectedFiles.count] : @"Select Items";
    _fileAllItem.enabled = _selectedFiles.count < _items.count;
    [self updateToolbar];
}

- (void)enterFileSelection
{
    if (_error || _items.count == 0) return;
    _selectingFiles = YES;
    [_selectedFiles removeAllObjects];
    if (!_fileDoneItem) {
        _fileDoneItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleProminent
                                                        target:self action:@selector(exitFileSelection)];
        _fileAllItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]
                                                         style:UIBarButtonItemStylePlain
                                                        target:self action:@selector(selectAllFiles)];
        _fileAllItem.accessibilityLabel = @"全选";
    }
    self.refreshControl.enabled = NO;
    self.navigationItem.rightBarButtonItems = @[_fileDoneItem, _fileAllItem];
    [self updateFileSelectionTitle];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

- (void)exitFileSelection
{
    if (!_selectingFiles) return;
    _selectingFiles = NO;
    [_selectedFiles removeAllObjects];
    self.refreshControl.enabled = YES;
    self.title = _baseTitle;
    [self restoreRightItems];
    [self updateToolbar];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

- (void)selectAllFiles
{
    for (WQItem *item in _items) [_selectedFiles addObject:item.path];
    [self updateFileSelectionTitle];
    [self.tableView reloadData];
}

- (NSArray<NSString *> *)selectedFilePaths
{
    return _selectedFiles.array.copy;
}

- (void)moveSelectedFiles
{
    NSArray<NSString *> *paths = [self selectedFilePaths];
    if (!paths.count) return;
    [self exitFileSelection];
    [self startMove:paths];
}

- (void)startMove:(NSArray<NSString *> *)paths
{
    wq_set_move_paths(paths);
    wq_alert(self, paths.count == 1 ? @"移动" : [NSString stringWithFormat:@"移动 %lu 个项目", (unsigned long)paths.count],
             @"请打开要移入的文件夹，然后轻点底部的“移到此处”。任何应用的文件夹都可以。");
}

- (void)cancelMove
{
    wq_set_move_paths(nil);
}

- (void)moveHere
{
    NSArray<NSString *> *paths = gWQMovePaths;
    if (![self canMoveHere]) return;
    NSString *dest = _path;
    wq_set_move_paths(nil);
    [self runIO:^BOOL(NSString **error) {
        NSUInteger failed = 0;
        NSString *first = nil;
        for (NSString *path in paths) {
            NSString *e = nil;
            if (!wq_move(path, dest, &e)) {
                failed++;
                if (!first) first = [NSString stringWithFormat:@"%@: %@", path.lastPathComponent, e ?: @"失败"];
            }
        }
        if (failed && error) {
            *error = paths.count == 1 ? first
                : [NSString stringWithFormat:@"%lu/%lu 个项目未被移动。\n\n%@", (unsigned long)failed, (unsigned long)paths.count, first];
        }
        return failed == 0;
    } failure:@"无法移动"];
}

- (void)deleteSelectedFiles
{
    NSArray<NSString *> *paths = [self selectedFilePaths];
    if (!paths.count) return;
    NSString *title = paths.count == 1 ? [NSString stringWithFormat:@"删除“%@”？", paths.firstObject.lastPathComponent]
                                       : [NSString stringWithFormat:@"删除 %lu 个项目？", (unsigned long)paths.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:@"文件会先复制到“备份”；只有空文件夹才会被删除。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self exitFileSelection];
        [self runIO:^BOOL(NSString **error) {
            NSUInteger failed = 0;
            NSString *first = nil;
            for (NSString *path in paths) {
                NSString *e = nil;
                if (!wq_delete(path, &e)) {
                    failed++;
                    if (!first) first = [NSString stringWithFormat:@"%@: %@", path.lastPathComponent, e ?: @"失败"];
                }
            }
            if (failed && error) {
                *error = paths.count == 1 ? first
                    : [NSString stringWithFormat:@"%lu/%lu 个项目未被删除。\n\n%@", (unsigned long)failed, (unsigned long)paths.count, first];
            }
            return failed == 0;
        } failure:@"无法删除"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// "Name.zip", or "Name 2.zip" when that is taken in this folder.
- (NSString *)unusedName:(NSString *)base extension:(NSString *)extension
{
    NSMutableSet<NSString *> *taken = [NSMutableSet new];
    for (WQItem *item in _all) [taken addObject:item.name.lowercaseString];
    for (NSUInteger n = 1; n < 10000; n++) {
        NSString *stem = n == 1 ? base : [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n];
        NSString *name = extension.length ? [stem stringByAppendingPathExtension:extension] : stem;
        if (![taken containsObject:name.lowercaseString]) return name;
    }
    return [NSString stringWithFormat:@"%@ %@", base, NSUUID.UUID.UUIDString];
}

// Runs a long ZIP job with a progress alert that can cancel it.
- (void)runArchiveJob:(NSString *)title failure:(NSString *)failureTitle
                 work:(BOOL (^)(WQArchiveCancelled cancelled, WQArchiveProgress progress, NSString **error, NSString **note))work
{
    WQScanCancellation *cancellation = [WQScanCancellation new];
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:title message:@"正在开始…"
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [hud addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction *__unused a) { [cancellation cancel]; }]];
    [self presentViewController:hud animated:YES completion:nil];
    __block CFAbsoluteTime lastUpdate = 0;
    WQArchiveProgress progress = ^(unsigned long long bytes) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastUpdate < 0.25) return;
        lastUpdate = now;
        NSString *text = wq_size_text(bytes);
        dispatch_async(dispatch_get_main_queue(), ^{ hud.message = text; });
    };
    WQArchiveCancelled cancelled = ^BOOL { return cancellation.isCancelled; };
    dispatch_async(wq_io(), ^{
        NSString *error = nil, *note = nil;
        BOOL ok = work(cancelled, progress, &error, &note);
        BOOL wasCancelled = cancellation.isCancelled;
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finish)(void) = ^{
                if (!ok && !wasCancelled) wq_alert(self, failureTitle, error ?: @"未知错误");
                else if (ok && note) wq_alert(self, title, note);
                [self reload];
            };
            if (self.presentedViewController == hud) [self dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

- (void)compressSelectedFiles
{
    NSArray<NSString *> *paths = [self selectedFilePaths];
    if (!paths.count) return;
    [self exitFileSelection];
    [self compressPaths:paths];
}

- (void)compressPaths:(NSArray<NSString *> *)paths
{
    NSString *base = paths.count == 1 ? paths.firstObject.lastPathComponent : @"归档";
    NSString *zipName = [self unusedName:base extension:@"zip"];
    NSString *dest = [_path stringByAppendingPathComponent:zipName];
    NSString *dir = _path;
    [self runArchiveJob:@"正在压缩…" failure:@"无法压缩"
                   work:^BOOL(WQArchiveCancelled cancelled, WQArchiveProgress progress, NSString **error, NSString **note) {
        // Write once, straight into the destination folder: a hidden staging
        // file next to the final name, fsync'd by wq_zip_write, then renamed
        // into place. No temporary-directory copy and no second pass over
        // the bytes. The staging name is a UUID, so it cannot collide with
        // a real file; the rename (moveItemAtPath, same folder) refuses to
        // overwrite if the destination appeared in the meantime.
        (void)wq_grant(dir);   // the writer opens the staging file directly
        NSString *staging = [dir stringByAppendingPathComponent:
                             [@".wq-zip-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSUInteger skipped = 0;
        BOOL ok = wq_zip_write(paths, staging, wq_app_archive_io(), cancelled, progress, &skipped, error);
        if (ok && cancelled()) ok = NO;
        if (ok) {
            NSError *renameError = nil;
            if (![NSFileManager.defaultManager moveItemAtPath:staging toPath:dest error:&renameError]) {
                ok = NO;
                if (error) *error = renameError.localizedDescription ?: @"无法放置 ZIP";
            }
        }
        if (!ok) [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        wq_log(@"compress: %lu item(s) -> %@: %@", (unsigned long)paths.count, dest, ok ? @"OK" : *error);
        if (ok && skipped)
            *note = [NSString stringWithFormat:@"已创建 %@。已排除 %lu 个符号链接或特殊文件。",
                     zipName, (unsigned long)skipped];
        return ok;
    }];
}

- (void)extractZip:(NSString *)zipPath
{
    NSString *base = zipPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *folder = [self unusedName:base.length ? base : @"归档" extension:nil];
    NSString *dest = [_path stringByAppendingPathComponent:folder];
    NSString *dir = _path;
    [self runArchiveJob:@"正在解压…" failure:@"无法解压"
                   work:^BOOL(WQArchiveCancelled cancelled, WQArchiveProgress progress, NSString **error, NSString **note) {
        // Extract once, straight into a hidden staging folder next to the
        // final name, then rename it into place. No temporary-directory
        // copy and no second pass over the bytes. On any failure or cancel
        // the staging folder is removed, so no partial destination is ever
        // left behind (previously a failed copy left `dest` half-filled).
        (void)wq_grant(dir);   // the extractor opens files directly below dir
        NSString *staging = [dir stringByAppendingPathComponent:
                             [@".wq-unzip-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        if (!wq_create_dir(staging, error)) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
            return NO;
        }
        // Single-copy space check: the archive is unpacked once, in place.
        // The old check halved the free space for the temp copy + final
        // copy; a ZIP that fits on disk was refused for needing twice its
        // size. Only the 256 MB reserve remains.
        struct statfs fs;
        unsigned long long available = statfs(dir.fileSystemRepresentation, &fs) == 0
            ? (unsigned long long)fs.f_bavail * fs.f_bsize : 0;
        unsigned long long reserve = 256ull * 1024 * 1024;
        unsigned long long limit = available > reserve ? available - reserve : 0;
        NSUInteger files = 0, skipped = 0;
        BOOL ok = wq_zip_extract(zipPath, staging, wq_app_archive_io(), limit, cancelled, progress, &files, &skipped, error);
        if (ok && cancelled()) ok = NO;
        if (ok) {
            NSError *renameError = nil;
            if (![NSFileManager.defaultManager moveItemAtPath:staging toPath:dest error:&renameError]) {
                ok = NO;
                if (error) *error = renameError.localizedDescription ?: @"无法放置解压出的文件夹";
            }
        }
        if (!ok) [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        wq_log(@"extract: %@ -> %@: %@ (%lu files, %lu skipped)", zipPath, dest, ok ? @"OK" : *error,
               (unsigned long)files, (unsigned long)skipped);
        if (ok && skipped)
            *note = [NSString stringWithFormat:@"已将 %lu 个文件解压到 %@。ZIP 中的 %lu 个符号链接已被排除。",
                     (unsigned long)files, folder, (unsigned long)skipped];
        return ok;
    }];
}

// Pull to refresh: container lists are scanned again instead of reused.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    [self reload];
}

- (void)reload
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanInFlight = YES;
    _scanNeedsRefresh = NO;
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
    NSString *path = _path;
    BOOL labels = _labels;
    BOOL enumerable = [@[@"/private/var/mobile/Containers/Data/Application",
                         @"/var/mobile/Containers/Data/Application",
                         @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/private/var/mobile/Containers/Data/InternalDaemon",
                         @"/var/mobile/Containers/Data/InternalDaemon",
                         // Listable on iOS 27; on iOS 26 only by scanning.
                         @"/private/var/mobile/Containers/Shared/AppGroup",
                         @"/var/mobile/Containers/Shared/AppGroup"] containsObject:path];
    // Directory-list loading runs on the interactive queue, so a long
    // archive job on wq_io() cannot block folder navigation. Stale loads
    // are harmless: every publish is guarded by _scanGeneration and the
    // loop exits early on cancellation.
    dispatch_async(wq_io_interactive(), ^{
        NSString *error = nil;
        NSArray *names = wq_list(path, &error);
        NSArray *childPaths = nil;
        // Parent gives no token on 27.x: discover children with fsgetpath.
        if (!names && enumerable && !cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = @"Scanning inodes…";
                [self updateHeader];
            });
            CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
            childPaths = wq_enumerate(path, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                // Time left, once the rate is known: an iOS 26 id scan can take most of an hour.
                double elapsed = CFAbsoluteTimeGetCurrent() - scanStarted;
                NSString *left = @"";
                if (elapsed > 5 && done > 0 && done < total) {
                    double remaining = elapsed * (double)(total - done) / (double)done;
                    left = remaining >= 90 ? [NSString stringWithFormat:@" · about %.0f min left", ceil(remaining / 60)]
                                           : @" · less than 2 min left";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = [NSString stringWithFormat:@"Scanning inodes… %lld%% · %lu found%@",
                                         total ? (long long)(done * 100 / total) : 0, (unsigned long)f, left];
                    [self updateHeader];
                });
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = nil;
                [self updateHeader];
            });
        }
        if (cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration) return;
                self->_scanInFlight = NO;
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
            });
            return;
        }
        NSMutableArray<WQItem *> *items = [NSMutableArray new];
        NSUInteger labelIssues = 0;
        NSArray *entries = names ?: childPaths;
        BOOL haveFullPaths = names == nil;
        NSUInteger entryIndex = 0, entryCount = entries.count;
        for (NSString *entry in entries) {
            entryIndex++;
            // Each container needs a token and its identifier: hundreds take a
            // few seconds, so show where it is.
            if (haveFullPaths && (entryIndex == 1 || entryIndex % 10 == 0)) {
                NSUInteger shown = entryIndex;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = [NSString stringWithFormat:@"Reading containers… %lu of %lu",
                                         (unsigned long)shown, (unsigned long)entryCount];
                    [self updateHeader];
                });
            }
            if (cancellation.isCancelled) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration) return;
                    self->_scanInFlight = NO;
                    self->_scanNeedsRefresh = YES;
                    self->_scanStatus = nil;
                    [self.refreshControl endRefreshing];
                    [self updateHeader];
                });
                return;
            }
            WQItem *item = [WQItem new];
            item.name = haveFullPaths ? entry.lastPathComponent : entry;
            item.path = haveFullPaths ? entry : [path stringByAppendingPathComponent:entry];
            NSString *name = item.name;
            // Enumerated containers need a token before they can be stat'd.
            if (haveFullPaths) {
                item.isDir = YES;
                BOOL token = wq_grant(item.path);
                NSString *bid = token ? wq_container_label(item.path) : nil;
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.label = token ? (wq_display_name(bid) ?: bid ?: @"（无标签）") : @"NO TOKEN";
                if (!token && labelIssues < 3) {
                    wq_log(@"label: no token for %@", item.path);
                    labelIssues++;
                } else if (token && !bid.length && labelIssues < 3) {
                    // Once per container per launch; refreshes would repeat it.
                    static NSMutableSet<NSString *> *reported;
                    @synchronized ([WQItem class]) {
                        if (!reported) reported = [NSMutableSet new];
                        if (![reported containsObject:item.path]) {
                            [reported addObject:item.path];
                            wq_log(@"label: no container identifier for %@", item.path);
                        }
                    }
                    labelIssues++;
                }
            }
            struct stat st;
            if (lstat(item.path.fileSystemRepresentation, &st) == 0) {
                item.isLink = S_ISLNK(st.st_mode);
                item.isDir = S_ISDIR(st.st_mode);
                item.isRegular = S_ISREG(st.st_mode);
                item.size = (unsigned long long)st.st_size;
                item.mode = st.st_mode;
                item.uid = st.st_uid;
                item.modified = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];
                item.created = [NSDate dateWithTimeIntervalSince1970:st.st_birthtimespec.tv_sec];
            }
            if (!haveFullPaths && labels && item.isDir && wq_looks_like_uuid(name)) {
                NSString *bid = wq_container_label(item.path);
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.label = wq_display_name(bid) ?: bid;
            }
            if (!haveFullPaths && item.isDir && !item.bundleID) {
                // App backups: AppBackups/<bundle id>/...
                if ([path.lastPathComponent isEqualToString:@"AppBackups"]) {
                    item.bundleID = name;
                    item.label = wq_display_name(name) ?: name;
                }
                // File backups mirror the original path; label container UUIDs
                // from the live container they came from.
                NSString *live = wq_backup_original_path(item.path);
                if (live && wq_looks_like_uuid(name)) {
                    NSString *bid = wq_container_label(live);
                    if (bid) { item.bundleID = bid; item.label = wq_display_name(bid) ?: bid; (void)wq_app_icon(bid); }
                }
                if ([path isEqualToString:wq_backup_root().stringByDeletingLastPathComponent]) {
                    if ([name isEqualToString:@"Backups"]) item.label = @"文件备份";
                    if ([name isEqualToString:@"AppBackups"]) item.label = @"应用备份";
                }
            }
            [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration) return;
            self->_scanInFlight = NO;
            if (cancellation.isCancelled) {
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
                return;
            }
            self->_all = items;
            [self applyFilter];
            self->_error = (names || childPaths != nil) ? nil
                : (error.length ? error
                   : !wq_app_group() ? @"WQ Files 没有 App Group，因此无法打开其他应用的文件夹。请使用保留 App Group 的工具重新签名（见 README 中的 Signing）。"
                   : wq_full_scan_was_declined() ? @"尚未列出：需要扫描全部文件。下拉即可开始。"
                   : @"无法列出此文件夹。容器枚举失败；请查看日志。");
            self->_scanStatus = nil;
            self->_lastReloadFinished = NSDate.date.timeIntervalSinceReferenceDate;
            [self.refreshControl endRefreshing];
            [self updateHeader];
            [self.tableView reloadData];
            [self updateBackupSelectionAvailability];
            if (self->_selectingBackups) [self updateBackupSelectionBar];
            if (self->_selectingFiles) {
                NSMutableSet<NSString *> *present = [NSMutableSet new];
                for (WQItem *item in items) [present addObject:item.path];
                for (NSString *path in self->_selectedFiles.array.copy)
                    if (![present containsObject:path]) [self->_selectedFiles removeObject:path];
                [self updateFileSelectionTitle];
            }
            [self updateToolbar];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _error ? 1 : (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_error) {
        c.text = @"无法打开此文件夹";
        BOOL container = [_path containsString:@"/Containers/"] || [_path containsString:@"/SystemGroup/"];
        c.secondaryText = container ? _error
            : [NSString stringWithFormat:@"%@\n\n此方法仅打开容器。请使用“应用数据”、“应用组”、"
               "“扩展数据”、“内部守护进程”或“系统组”来打开 /private/var 内的文件夹。", _error];
        c.secondaryTextProperties.numberOfLines = 0;
        c.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQItem *item = _items[(NSUInteger)indexPath.row];
    c.text = item.label ?: item.name;
    BOOL byCreated = wq_sort_key() == WQSortCreated;
    NSString *date = wq_folder_date_text(byCreated ? item.created : item.modified);
    if (byCreated) date = [@"创建于 " stringByAppendingString:date];
    NSString *detail = item.isDir ? date : [NSString stringWithFormat:@"%@ · %@", wq_size_text(item.size), date];
    if (item.label) detail = [NSString stringWithFormat:@"%@\n%@", item.name, detail];
    if (item.isLink) detail = [@"符号链接 · " stringByAppendingString:detail];
    c.secondaryText = detail;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    UIImage *appIcon = item.bundleID ? wq_app_icon(item.bundleID) : nil;
    c.image = appIcon ?: [UIImage systemImageNamed:item.isDir ? @"folder.fill" : (item.isLink ? @"link" : @"doc")];
    if (appIcon) c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    if (_selectingFiles) {
        cell.accessoryType = [_selectedFiles containsObject:item.path]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (_selectingBackups) {
        BOOL selectable = wq_backup_unit_deletable(item.path);
        cell.accessoryType = selectable && [_selectedBackups containsObject:item.path]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = item.isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_error || indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    if (!_selectingBackups) return indexPath;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    return wq_backup_unit_deletable(item.path) ? indexPath : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingFiles) {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
        NSString *path = _items[(NSUInteger)indexPath.row].path;
        if ([_selectedFiles containsObject:path]) [_selectedFiles removeObject:path];
        else [_selectedFiles addObject:path];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self updateFileSelectionTitle];
        return;
    }
    if (_selectingBackups) {
        if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
        WQItem *selected = _items[(NSUInteger)indexPath.row];
        if (!wq_backup_unit_deletable(selected.path)) return;
        [_selectedBackups addObject:selected.path];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self updateBackupSelectionBar];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_error) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    UIViewController *next;
    if (item.isLink) {
        wq_alert(self, @"符号链接",
                 @"WQ Files 在查看、分享或编辑时不跟随符号链接。请使用“复制路径”显式打开目标。");
        return;
    }
    if (item.isDir) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:item.path title:item.label ?: item.name];
        dir.readOnly = self.readOnly;
        next = dir;
    } else {
        if (!item.isRegular) {
            wq_alert(self, @"无法打开此项目", item.isLink
                     ? @"查看、分享或编辑时不跟随符号链接。"
                     : @"只能查看常规文件。");
            return;
        }
        _scanNeedsRefresh = YES;
        wq_open_file(self.navigationController, item.path, self.readOnly, WQOpenAuto);
        return;
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_selectingBackups) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    [_selectedBackups removeObject:item.path];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateBackupSelectionBar];
}

// Swipe left or right to delete, with the same rules and confirmation as the
// long-press menu (files are backed up first; backups only as whole units).
- (UISwipeActionsConfiguration *)deleteSwipeForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingBackups || _selectingFiles || _error) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    BOOL backupUnit = item.isDir && wq_backup_unit_deletable(item.path);
    BOOL regular = !self.readOnly && !_backupStorage;
    if (!backupUnit && !regular) return nil;
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *__unused a, UIView *__unused view, void (^done)(BOOL)) {
        WQDirViewController *strongSelf = weakSelf;
        WQItem *current = nil;
        if (strongSelf && (NSUInteger)indexPath.row < strongSelf->_items.count &&
            [strongSelf->_items[(NSUInteger)indexPath.row].path isEqualToString:itemPath])
            current = strongSelf->_items[(NSUInteger)indexPath.row];
        // The row stays until the confirmed delete reloads the folder.
        done(NO);
        if (!current) return;
        if (backupUnit) [strongSelf confirmDeleteBackup:current];
        else [strongSelf confirmDelete:current];
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self deleteSwipeForRowAtIndexPath:indexPath];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self deleteSwipeForRowAtIndexPath:indexPath];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (_selectingBackups || _selectingFiles || _error) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    WQItem *(^currentItem)(void) = ^WQItem *{
        WQDirViewController *strongSelf = weakSelf;
        if (!strongSelf || indexPath.section != 0 || (NSUInteger)indexPath.row >= strongSelf->_items.count) return nil;
        WQItem *current = strongSelf->_items[(NSUInteger)indexPath.row];
        return [current.path isEqualToString:itemPath] ? current : nil;
    };
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        WQItem *current = currentItem();
        WQDirViewController *strongSelf = weakSelf;
        if (!current || !strongSelf) return nil;
        NSMutableArray *actions = [NSMutableArray new];
        if (current.isDir) {
            [actions addObject:[UIAction actionWithTitle:@"以 ZIP 分享（隔空投送…）" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share_folder(weakSelf, latest.path, nil, cell);
            }]];
        }
        if (!current.isDir && current.isRegular) {
            [actions addObject:[UIAction actionWithTitle:@"分享" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share(weakSelf, latest.path, cell);
            }]];
            NSString *original = wq_backup_original_path(current.path);
            if (original) {
                [actions addObject:[UIAction actionWithTitle:@"恢复到原始位置"
                                                       image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    WQItem *latest = currentItem();
                    if (latest && weakSelf) [weakSelf restoreBackup:latest.path to:original];
                }]];
            }
        }
        if (!current.isDir && current.isRegular) {
            BOOL ro = weakSelf.readOnly;
            [actions addObject:[UIMenu menuWithTitle:@"打开方式" image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil
                                             options:0 children:@[
                [UIAction actionWithTitle:@"Plist 编辑器" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenPlist); }],
                [UIAction actionWithTitle:@"文本 / 图片" image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenText); }],
                [UIAction actionWithTitle:@"十六进制查看器" image:[UIImage systemImageNamed:@"number"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenHex); }],
                [UIAction actionWithTitle:@"SQLite 查看器" image:[UIImage systemImageNamed:@"tablecells"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenSQLite); }],
                [UIAction actionWithTitle:@"媒体播放器" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenMedia); }],
            ]]];
        }
        [actions addObject:[UIAction actionWithTitle:@"复制路径" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil handler:^(UIAction *__unused a) {
            WQItem *latest = currentItem();
            if (latest) UIPasteboard.generalPasteboard.string = latest.path;
        }]];
        if (current.label) {
            [actions addObject:[UIAction actionWithTitle:@"复制标识符" image:[UIImage systemImageNamed:@"tag"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) UIPasteboard.generalPasteboard.string = latest.bundleID ?: latest.label;
            }]];
        }
        if (current.isDir && wq_backup_unit_deletable(current.path)) {
            UIAction *remove = [UIAction actionWithTitle:@"删除备份…" image:[UIImage systemImageNamed:@"trash"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf confirmDeleteBackup:latest];
            }];
            remove.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:remove];
        }
        if ([strongSelf canEditHere]) {
            if (!current.isDir && current.isRegular &&
                [current.name.pathExtension caseInsensitiveCompare:@"zip"] == NSOrderedSame) {
                [actions addObject:[UIAction actionWithTitle:@"解压" image:[UIImage systemImageNamed:@"archivebox"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    WQItem *latest = currentItem();
                    if (latest) [weakSelf extractZip:latest.path];
                }]];
            }
            [actions addObject:[UIAction actionWithTitle:@"压缩" image:[UIImage systemImageNamed:@"doc.zipper"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf compressPaths:@[latest.path]];
            }]];
            [actions addObject:[UIAction actionWithTitle:@"移动…" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf startMove:@[latest.path]];
            }]];
        }
        if (!strongSelf.readOnly && !strongSelf->_backupStorage) {
            [actions addObject:[UIAction actionWithTitle:@"重命名" image:[UIImage systemImageNamed:@"pencil"]
                                              identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf promptRename:latest]; }]];
            UIAction *del = [UIAction actionWithTitle:@"删除" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf confirmDelete:latest]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:del];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

#pragma mark Actions

- (void)runIO:(BOOL (^)(NSString **error))work failure:(NSString *)failureTitle
{
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        BOOL ok = work(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) wq_alert(self, failureTitle, error ?: @"未知错误");
            [self reload];
        });
    });
}

- (void)promptNewFolder
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹" message:_path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"名称"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [self->_path stringByAppendingPathComponent:name];
        [self runIO:^BOOL(NSString **error) { return wq_create_dir(path, error); } failure:@"无法创建文件夹"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRename:(WQItem *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名" message:item.path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = item.name; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        [self runIO:^BOOL(NSString **error) { return wq_rename(item.path, name, error); } failure:@"无法重命名"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteBackup:(WQItem *)item
{
    BOOL bundle = [item.path.stringByDeletingLastPathComponent isEqualToString:wq_app_backup_root()];
    NSString *message = bundle
        ? [NSString stringWithFormat:@"%@\n\n这将删除该应用的全部备份。此操作无法撤销。", item.path]
        : [NSString stringWithFormat:@"%@\n\n这将删除选定的备份。此操作无法撤销。", item.path];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除备份？"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete_backup(item.path, error); } failure:@"无法删除备份"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDelete:(WQItem *)item
{
    NSString *message;
    if (item.isLink) {
        message = [NSString stringWithFormat:@"%@\n\n仅删除符号链接本身；其目标不会改变。", item.path];
    } else if (item.isDir) {
        message = [NSString stringWithFormat:@"%@\n\n只能删除空文件夹。", item.path];
    } else if (item.isRegular) {
        message = [NSString stringWithFormat:@"%@\n\n副本保留在“备份”中。", item.path];
    } else {
        message = [NSString stringWithFormat:@"%@\n\n此特殊文件将被删除；不保留备份。", item.path];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"删除“%@”？", item.name]
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete(item.path, error); } failure:@"无法删除"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreBackup:(NSString *)backup to:(NSString *)original
{
    NSString *message = [NSString stringWithFormat:@"Write this backup back to\n%@?\n\nIf a file is there now, it is backed up first.", original];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) {
            struct stat st;
            return wq_stat(original, &st) ? wq_write_from_file(original, backup, error)
                                          : wq_create_file_from(original, backup, error);
        } failure:@"恢复失败"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFile
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    _importingFolder = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importFolder
{
    // Folders can't be handed over as a copy; the picker grants temporary
    // access to the folder itself, which is copied with everything inside.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    _importingFolder = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

// A name in dir that nothing uses yet: "Name", "Name 2", … (keeps the extension).
static NSString *wq_free_name_in(NSString *dir, NSString *name, NSMutableSet<NSString *> *claimed)
{
    NSString *ext = name.pathExtension, *stem = name.stringByDeletingPathExtension;
    if (!stem.length) { stem = name; ext = @""; }
    for (NSUInteger n = 1; n < 10000; n++) {
        NSString *candidate = n == 1 ? name : [NSString stringWithFormat:@"%@ %lu", stem, (unsigned long)n];
        if (n > 1 && ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
        struct stat st;
        if ([claimed containsObject:candidate.lowercaseString] ||
            wq_stat([dir stringByAppendingPathComponent:candidate], &st)) continue;
        [claimed addObject:candidate.lowercaseString];
        return candidate;
    }
    return nil;
}

// Shows a progress alert while work runs on the IO queue, then reports.
- (void)runBusy:(NSString *)title failure:(NSString *)failureTitle
           work:(BOOL (^)(NSString **error, NSString **note))work
{
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:title message:@"请稍候…"
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        NSString *error = nil, *note = nil;
        BOOL ok = work(&error, &note);
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finish)(void) = ^{
                if (!ok) wq_alert(self, failureTitle, error ?: @"未知错误");
                else if (note) wq_alert(self, title, note);
                [self reload];
            };
            if (self.presentedViewController == hud) [self dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;
    if (_importingFolder) { [self importFolders:urls]; return; }
    // One file: the existing flow, which offers to replace a file of the same name.
    if (urls.count == 1) { [self importSingleFile:urls.firstObject.path]; return; }
    // Several files: same-named ones get a free name ("Name 2.ext") instead of
    // a question per file. The picker's local copies are removed afterwards.
    NSString *dir = _path;
    NSArray<NSString *> *sources = [urls valueForKey:@"path"];
    [self runBusy:@"正在导入…" failure:@"导入失败" work:^BOOL(NSString **error, NSString **note) {
        NSMutableSet<NSString *> *claimed = [NSMutableSet new];
        NSUInteger done = 0, renamed = 0;
        NSString *first = nil;
        for (NSString *source in sources) {
            NSString *name = wq_free_name_in(dir, source.lastPathComponent, claimed);
            NSString *e = nil;
            BOOL ok = name && wq_create_file_from([dir stringByAppendingPathComponent:name], source, &e);
            [NSFileManager.defaultManager removeItemAtPath:source error:nil];
            if (ok) { done++; if (![name isEqualToString:source.lastPathComponent]) renamed++; }
            else if (!first) first = [NSString stringWithFormat:@"%@: %@", source.lastPathComponent, e ?: @"没有可用名称"];
        }
        wq_log(@"import: %lu of %lu files into %@", (unsigned long)done, (unsigned long)sources.count, dir);
        if (done < sources.count) {
            *error = [NSString stringWithFormat:@"已导入 %lu/%lu 个文件。\n\n%@",
                      (unsigned long)done, (unsigned long)sources.count, first];
            return NO;
        }
        if (renamed) *note = [NSString stringWithFormat:@"已导入 %lu 个文件，其中 %lu 个因重名被加了编号。",
                              (unsigned long)done, (unsigned long)renamed];
        return YES;
    }];
}

- (void)importFolders:(NSArray<NSURL *> *)urls
{
    NSString *dir = _path;
    [self runBusy:@"正在导入…" failure:@"导入失败" work:^BOOL(NSString **error, NSString **note) {
        NSMutableSet<NSString *> *claimed = [NSMutableSet new];
        NSMutableArray<NSString *> *renamed = [NSMutableArray new];
        for (NSURL *url in urls) {
            BOOL scoped = [url startAccessingSecurityScopedResource];
            NSString *name = wq_free_name_in(dir, url.lastPathComponent, claimed);
            __block BOOL ok = NO;
            __block NSString *e = nil;
            if (name) {
                NSString *dest = [dir stringByAppendingPathComponent:name];
                // A coordinated read makes cloud folders download first.
                NSError *coordError = nil;
                [[NSFileCoordinator new] coordinateReadingItemAtURL:url options:0 error:&coordError byAccessor:^(NSURL *readable) {
                    NSString *copyError = nil;
                    ok = wq_create_dir(dest, &copyError) && wq_copy_contents(readable.path, dest, &copyError);
                    e = copyError;
                }];
                if (coordError) e = e ?: coordError.localizedDescription;
                if (!ok && e && wq_stat(dest, &(struct stat){0}))
                    e = [NSString stringWithFormat:@"%@\n\n其中一部分可能已在 %@ 中。", e, name];
            } else {
                e = @"此文件夹中没有可用名称";
            }
            if (scoped) [url stopAccessingSecurityScopedResource];
            wq_log(@"import folder: %@ -> %@/%@: %@", url.path, dir, name, ok ? @"OK" : e);
            if (!ok) { *error = [NSString stringWithFormat:@"%@: %@", url.lastPathComponent, e ?: @"失败"]; return NO; }
            if (![name isEqualToString:url.lastPathComponent]) [renamed addObject:name];
        }
        if (renamed.count)
            *note = [NSString stringWithFormat:@"已存在同名文件夹，因此导入的文件夹命名为 %@。",
                     [renamed componentsJoinedByString:@", "]];
        return YES;
    }];
}

- (void)importSingleFile:(NSString *)source
{
    // The picker hands over a local copy (asCopy). It is streamed into place,
    // never read into memory, and the existence check runs off the main thread.
    NSString *dest = [_path stringByAppendingPathComponent:source.lastPathComponent];
    void (^cleanup)(void) = ^{ [NSFileManager.defaultManager removeItemAtPath:source error:nil]; };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct stat st;
        BOOL exists = wq_stat(dest, &st);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!exists) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_create_file_from(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"导入失败"];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"替换现有文件？"
                message:[NSString stringWithFormat:@"%@ 已存在，替换前会先备份。", dest]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction *__unused a) { cleanup(); }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_write_from_file(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"导入失败"];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

#pragma mark - System groups

// The SystemGroup parent gets no token on 27.0.1, so it cannot be listed.
// Known container names are checked one by one (lstat works without access).
@interface WQSystemGroupsViewController : UITableViewController
@end

@implementation WQSystemGroupsViewController {
    NSArray<NSString *> *_names;
    BOOL _listed;
}

static NSString *const kSystemGroupRoot = @"/private/var/containers/Shared/SystemGroup";

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"系统组";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self action:@selector(tryName)];
    dispatch_async(wq_io(), ^{
        NSArray *listed = wq_list(kSystemGroupRoot, NULL);
        NSArray *names = listed;
        if (!names) {
            NSArray *known = @[
                @"systemgroup.com.apple.configurationprofiles", @"systemgroup.com.apple.mobilegestaltcache",
                @"systemgroup.com.apple.osanalytics", @"systemgroup.com.apple.lsd.iconscache",
                @"systemgroup.com.apple.lsd.identifiers", @"systemgroup.com.apple.ManagedSettings",
                @"systemgroup.com.apple.sharedpclogging", @"systemgroup.com.apple.media.shared.books",
                @"systemgroup.com.apple.nsurlstoragedresources", @"systemgroup.com.apple.pisco.suinfo",
                @"systemgroup.com.apple.icloud.findmydevice.managed", @"systemgroup.com.apple.mobilestoragemounter",
                @"systemgroup.com.apple.mobileactivationd", @"systemgroup.com.apple.sensorkit",
                @"systemgroup.com.apple.powerlog", @"systemgroup.com.apple.diagnosticextensionsd",
                @"systemgroup.com.apple.mediaanalysisd", @"systemgroup.com.apple.translationd",
                @"systemgroup.com.apple.chronod", @"systemgroup.com.apple.coreaudio",
                @"systemgroup.com.apple.ManagedConfiguration.ExternalTrust", @"systemgroup.com.apple.cfprefsd",
            ];
            NSMutableArray *found = [NSMutableArray new];
            for (NSString *name in known) {
                struct stat st;
                NSString *p = [kSystemGroupRoot stringByAppendingPathComponent:name];
                if (lstat(p.fileSystemRepresentation, &st) == 0) [found addObject:name];
            }
            names = found;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_listed = listed != nil;
            self->_names = [names sortedArrayUsingSelector:@selector(compare:)];
            [self.tableView reloadData];
        });
    });
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_names) return @"正在加载…";
    return _listed ? nil : @"This folder cannot be listed on this iOS version. Known names that exist are shown; tap + to try another name.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_names.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"g"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"g"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = [_names[(NSUInteger)indexPath.row] stringByReplacingOccurrencesOfString:@"systemgroup." withString:@""];
    c.image = [UIImage systemImageNamed:@"folder.fill"];
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = _names[(NSUInteger)indexPath.row];
    [self.navigationController pushViewController:[[WQDirViewController alloc]
        initWithPath:[kSystemGroupRoot stringByAppendingPathComponent:name] title:nil] animated:YES];
}

- (void)tryName
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"打开系统组" message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = @"systemgroup.com.apple.";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [kSystemGroupRoot stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) {
            wq_alert(self, @"未找到", path);
            return;
        }
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil] animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Log

@interface WQLogViewController : UIViewController
@end

@implementation WQLogViewController {
    UITextView *_textView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:_textView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(share:)];
}

// App version, device and iOS first, so a Log someone sends in says where it
// came from.
- (NSString *)fullLog
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"WQ Files %@ (%@)\n%@\n\n%@",
            info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?", wq_device_line(), wq_log_text()];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _textView.text = [self fullLog];
}

- (void)share:(UIBarButtonItem *)sender
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[self fullLog]]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

@end

#pragma mark - Navigation

// Adds a Home button next to Back on screens two or more levels deep. Editors
// guard Back, Home and the interactive edge swipe through WQUnsavedEditing.
@interface WQNavigationController : UINavigationController <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@end

@implementation WQNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
    self.interactivePopGestureRecognizer.delegate = self;
}

- (void)navigationController:(UINavigationController *)nav willShowViewController:(UIViewController *)vc animated:(BOOL)animated
{
    BOOL toolbar = [vc isKindOfClass:WQDirViewController.class] && [(WQDirViewController *)vc wq_wantsToolbar];
    [nav setToolbarHidden:!toolbar animated:animated];
    NSUInteger depth = [nav.viewControllers indexOfObject:vc];
    if (depth == NSNotFound || depth < 2) {
        if (vc.navigationItem.leftBarButtonItem.tag == 0x484f4d45) vc.navigationItem.leftBarButtonItem = nil;
        return;
    }
    if (vc.navigationItem.leftBarButtonItem) return;
    UIBarButtonItem *home = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"house"]
                                                             style:UIBarButtonItemStylePlain target:self action:@selector(goHome)];
    home.tag = 0x484f4d45;   // "HOME"
    home.accessibilityLabel = @"主页";
    vc.navigationItem.leftItemsSupplementBackButton = YES;
    vc.navigationItem.leftBarButtonItem = home;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer != self.interactivePopGestureRecognizer) return YES;
    if (self.viewControllers.count <= 1) return NO;
    UIViewController<WQUnsavedEditing> *editor = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    if (![editor conformsToProtocol:@protocol(WQUnsavedEditing)] || !editor.wq_needsLeaveConfirmation) return YES;
    __weak typeof(self) weakSelf = self;
    [editor confirmLeaveThen:^{ [weakSelf popViewControllerAnimated:YES]; }];
    return NO;
}

- (void)goHome
{
    UIViewController<WQUnsavedEditing> *top = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    __weak typeof(self) weakSelf = self;
    void (^home)(void) = ^{ [weakSelf popToRootViewControllerAnimated:YES]; };
    if ([top conformsToProtocol:@protocol(WQUnsavedEditing)]) [top confirmLeaveThen:home];
    else home();
}

@end

#pragma mark - Root

@interface WQRootViewController : UITableViewController
@end

@implementation WQRootViewController {
    NSArray<NSArray<NSString *> *> *_locations;  // title, path, symbol
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"WQ Files";
        _locations = @[
            @[@"应用数据", @"/private/var/mobile/Containers/Data/Application", @"square.grid.2x2"],
            @[@"应用组", @"/private/var/mobile/Containers/Shared/AppGroup", @"square.stack.3d.up"],
            @[@"扩展数据", @"/private/var/mobile/Containers/Data/PluginKitPlugin", @"puzzlepiece.extension"],
            @[@"内部守护进程", @"/private/var/mobile/Containers/Data/InternalDaemon", @"gearshape.2"],
        ];
        if (wq_system_areas_reachable())
            _locations = [_locations arrayByAddingObject:@[@"系统数据", @"/private/var/containers/Data/System", @"cpu"]];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.tableFooterView = [self authorFooter];
    dispatch_async(wq_io(), ^{
        NSString *recovery = wq_recover_interrupted_restore();
        if (recovery) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(self, @"恢复记录", recovery);
            });
        }
        (void)wq_app_group();   // resolves (and logs) the group off the main thread
    });
}

// Signing check, once the start screen is on screen (an alert presented
// while it is still loading would be dropped).
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    static BOOL checked;
    if (checked) return;
    checked = YES;
    dispatch_async(wq_io(), ^{
        NSString *group = wq_app_group();
        if (group) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"签名问题：没有 App Group"
                message:@"WQ Files 需要 App Group 才能访问其他应用的文件夹，而签名工具已将其移除。"
                        @"没有它，什么都打不开，应用列表会保持空白或显示“NO TOKEN”。\n\n"
                        @"请使用 AltStore、SideStore 或 Sideloadly 重新安装 WQ Files（它们会创建 App Group），"
                        @"或使用包含 App Group 的配置文件。通配符证书（如许多 "
                        @"Feather/ESign 配置所用的）则不行。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"签名帮助" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
                [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/kolbicz/WQFiles#signing-the-app-group"]
                                                 options:@{} completionHandler:nil];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

// "by kolbicz" with GitHub and X links, under the last section.
- (UIView *)authorFooter
{
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 128)];
    UILabel *by = [UILabel new];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    by.text = [NSString stringWithFormat:@"WQ Files %@ (%@)，作者 kolbicz",
               info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
    by.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    by.textColor = UIColor.secondaryLabelColor;

    UIButton *(^link)(NSString *, NSString *, NSString *) = ^UIButton *(NSString *title, NSString *symbol, NSString *url) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
        cfg.title = title;
        cfg.image = [UIImage systemImageNamed:symbol];
        cfg.imagePadding = 6;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.buttonSize = UIButtonConfigurationSizeSmall;
        return [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        }]];
    };
    UIStackView *links = [[UIStackView alloc] initWithArrangedSubviews:@[
        link(@"GitHub", @"chevron.left.forwardslash.chevron.right", @"https://github.com/kolbicz"),
        link(@"@_kolbicz", @"at", @"https://x.com/_kolbicz"),
    ]];
    links.spacing = 12;

    UIButtonConfiguration *creditCfg = [UIButtonConfiguration plainButtonConfiguration];
    creditCfg.attributedTitle = [[NSAttributedString alloc] initWithString:@"Sandbox escape: worse_query by @forcequitOS"
        attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]}];
    creditCfg.buttonSize = UIButtonConfigurationSizeSmall;
    UIButton *credit = [UIButton buttonWithConfiguration:creditCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://x.com/forcequitOS"] options:@{} completionHandler:nil];
    }]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[by, links, credit]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
    ]];
    return footer;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // System Groups is the extra last row, on iOS 27 only.
    return section == 0 ? (NSInteger)_locations.count + (wq_system_areas_reachable() ? 1 : 0) : 6;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"容器" : @"工具";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 && !wq_system_areas_reachable())
        return @"在 iOS 26 上无法访问系统数据和系统组（worse_query 仅在 iOS 27 上覆盖它们），内部守护进程需要扫描每个文件 ID：首次扫描在常用设备上可能需要近一小时，之后只检查新文件。";
    return section == 1
        ? @"被覆盖和删除的文件会先复制到“备份”（在“文件”应用中也可查看）。长按备份可恢复。"
        : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"r"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            c.text = loc[0];
            c.image = [UIImage systemImageNamed:loc[2]];
        } else {
            c.text = @"系统组";
            c.image = [UIImage systemImageNamed:@"lock.square.stack"];
        }
    } else {
        NSArray *tools = @[@[@"应用", @"square.grid.3x3"], @[@"缓存清理", @"trash"], @[@"前往路径…", @"arrow.right.circle"],
                           @[@"应用备份", @"clock.arrow.circlepath"], @[@"备份", @"clock.arrow.circlepath"], @[@"日志", @"doc.plaintext"]];
        c.text = tools[(NSUInteger)indexPath.row][0];
        c.image = [UIImage systemImageNamed:tools[(NSUInteger)indexPath.row][1]];
    }
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            next = [[WQDirViewController alloc] initWithPath:loc[1] title:loc[0]];
        } else {
            next = [WQSystemGroupsViewController new];
        }
    } else if (indexPath.row == 0) {
        next = [WQAppsViewController new];
    } else if (indexPath.row == 1) {
        next = [WQCacheCleanerViewController new];
    } else if (indexPath.row == 2) {
        [self goToPath];
        return;
    } else if (indexPath.row == 3) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_app_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        next = [[WQDirViewController alloc] initWithPath:wq_app_backup_root() title:@"应用备份"];
    } else if (indexPath.row == 4) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        next = [[WQDirViewController alloc] initWithPath:wq_backup_root() title:@"备份"];
    } else {
        next = [WQLogViewController new];
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)goToPath
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"前往路径" message:@"文件夹或文件路径"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = UIPasteboard.generalPasteboard.hasStrings && [UIPasteboard.generalPasteboard.string hasPrefix:@"/"]
            ? UIPasteboard.generalPasteboard.string : @"/private/var/";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *path = alert.textFields.firstObject.text.stringByStandardizingPath;
        if (![path hasPrefix:@"/"]) return;
        dispatch_async(wq_io(), ^{
            struct stat st;
            BOOL exists = wq_stat(path, &st);
            BOOL isDir = exists && S_ISDIR(st.st_mode);
            if (exists && S_ISLNK(st.st_mode)) {
                struct stat target;
                isDir = stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!exists) {
                    wq_alert(self, @"未找到", path);
                    return;
                }
                if (!isDir) { wq_open_file(self.navigationController, path, NO, WQOpenAuto); return; }
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil]
                                                     animated:YES];
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - App

@interface WQSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WQSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [[WQNavigationController alloc] initWithRootViewController:[WQRootViewController new]];
    [window makeKeyAndVisible];
    self.window = window;
}

@end

#pragma mark - Full scan: confirmation and progress window

static UIViewController *wq_top_view_controller(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            UIViewController *top = window.rootViewController;
            while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
            return top;
        }
    }
    return nil;
}

static NSString *wq_duration_text(double seconds)
{
    if (seconds < 90) return @"约 1 分钟";
    if (seconds < 3600) return [NSString stringWithFormat:@"约 %.0f 分钟", ceil(seconds / 60)];
    return [NSString stringWithFormat:@"约 %.1f 小时", seconds / 3600];
}

static NSString *wq_count_text(int64_t n)
{
    if (n >= 1000000) return [NSString stringWithFormat:@"%.0f 百万", n / 1e6];
    return [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle];
}

@interface WQScanWindowController : UIViewController
- (void)updateDone:(int64_t)done total:(int64_t)total;
@end

@implementation WQScanWindowController {
    UIProgressView *_bar;
    UILabel *_status;
    CFAbsoluteTime _started;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _started = CFAbsoluteTimeGetCurrent();
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:40 weight:UIImageSymbolWeightRegular];
    icon.tintColor = UIColor.tintColor;
    UILabel *title = [UILabel new];
    title.text = @"正在扫描全部文件";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    UILabel *text = [UILabel new];
    text.numberOfLines = 0;
    text.textAlignment = NSTextAlignmentCenter;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.textColor = UIColor.secondaryLabelColor;
    text.text = @"iOS 不允许 WQ Files 直接列出这些文件夹，因此它会逐一检查此设备上的每个文件。"
                @"这仅在首次较慢：之后的扫描只检查新文件。\n\n"
                @"请保持 WQ Files 打开。切换到其他应用或锁定屏幕会暂停扫描。";
    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _status = [UILabel new];
    _status.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize
                                                    weight:UIFontWeightRegular];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.text = @"正在开始…";
    UIButton *hide = [UIButton buttonWithConfiguration:UIButtonConfiguration.borderedButtonConfiguration primaryAction:
        [UIAction actionWithTitle:@"隐藏" image:nil identifier:nil handler:^(UIAction *__unused a) {
            [self dismissViewControllerAnimated:YES completion:nil];
        }]];
    UIButtonConfiguration *stopConfig = UIButtonConfiguration.borderedButtonConfiguration;
    stopConfig.baseForegroundColor = UIColor.systemRedColor;
    UIButton *stop = [UIButton buttonWithConfiguration:stopConfig primaryAction:
        [UIAction actionWithTitle:@"停止扫描" image:nil identifier:nil handler:^(UIAction *__unused a) {
            wq_full_scan_stop();
            [self dismissViewControllerAnimated:YES completion:nil];
        }]];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[hide, stop]];
    buttons.spacing = 12;
    buttons.distribution = UIStackViewDistributionFillEqually;
    UILabel *note = [UILabel new];
    note.numberOfLines = 0;
    note.textAlignment = NSTextAlignmentCenter;
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.textColor = UIColor.tertiaryLabelColor;
    note.text = @"隐藏后扫描会继续运行；完成后列表将填满。";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, text, _bar, _status, buttons, note]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
        [_bar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [text.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [note.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (void)updateDone:(int64_t)done total:(int64_t)total
{
    if (total <= 0) return;
    float fraction = (float)((double)done / (double)total);
    [_bar setProgress:fraction animated:NO];
    double elapsed = CFAbsoluteTimeGetCurrent() - _started;
    NSString *left = @"";
    if (elapsed > 5 && done > 0 && done < total) {
        double remaining = elapsed * (double)(total - done) / (double)done;
        left = [@" · " stringByAppendingString:[wq_duration_text(remaining) stringByAppendingString:@" 剩余"]];
    }
    _status.text = [NSString stringWithFormat:@"%.0f%%%@", fraction * 100, left];
}

@end

static WQScanWindowController *gScanWindow;
static UIBackgroundTaskIdentifier gScanBackgroundTask;   // 0 is UIBackgroundTaskInvalid

// Called on a scan thread: asks on the main thread and waits for the answer.
static BOOL wq_confirm_full_scan(NSString *what, int64_t ids, double seconds)
{
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL start = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = wq_top_view_controller();
        if (!top) { dispatch_semaphore_signal(answered); return; }   // not in front: don't scan unasked
        NSString *message = [NSString stringWithFormat:
            @"要列出 %@，WQ Files 需要逐一检查此设备上的每个文件：共 %@ 个文件，%@。\n\n"
            @"这仅在首次需要；之后的扫描只检查新文件，只需几秒。\n\n"
            @"扫描期间请保持 WQ Files 打开。", what, wq_count_text(ids), wq_duration_text(seconds)];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描全部文件？" message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"暂不" style:UIAlertActionStyleCancel handler:^(UIAlertAction *__unused a) {
            dispatch_semaphore_signal(answered);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"开始扫描" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            start = YES;
            // A little extra time when the user switches away (iOS grants about 30 s).
            if (gScanBackgroundTask == UIBackgroundTaskInvalid) {
                gScanBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"WQ full scan" expirationHandler:^{
                    [UIApplication.sharedApplication endBackgroundTask:gScanBackgroundTask];
                    gScanBackgroundTask = UIBackgroundTaskInvalid;
                }];
            }
            WQScanWindowController *window = [WQScanWindowController new];
            window.modalPresentationStyle = UIModalPresentationPageSheet;
            window.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                                          UISheetPresentationControllerDetent.largeDetent];
            window.sheetPresentationController.prefersGrabberVisible = YES;
            gScanWindow = window;
            dispatch_semaphore_signal(answered);
            // After the alert has gone (presenting during its dismissal fails).
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIViewController *host = wq_top_view_controller();
                if (gScanWindow == window && host && host != window) [host presentViewController:window animated:YES completion:nil];
            });
        }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    return start;
}

static void wq_full_scan_progress(int64_t done, int64_t total, BOOL finished)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!finished) { [gScanWindow updateDone:done total:total]; return; }
        WQScanWindowController *window = gScanWindow;
        gScanWindow = nil;
        if (window.presentingViewController && !window.isBeingDismissed) [window dismissViewControllerAnimated:YES completion:nil];
        if (gScanBackgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:gScanBackgroundTask];
            gScanBackgroundTask = UIBackgroundTaskInvalid;
        }
    });
}

@interface WQAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WQAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    config.delegateClass = WQSceneDelegate.class;
    return config;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Container folders get their bundle id from the LaunchServices database
        // when the identifier attribute can't be read (iOS 27.2).
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(wq_confirm_full_scan, wq_full_scan_progress);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WQAppDelegate.class));
    }
}
