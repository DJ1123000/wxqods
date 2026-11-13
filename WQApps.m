//
//  WQApps.m
//  WQ Files app backup and restore manager
//  GPL-3.0-or-later.
//

#import "WQApps.h"
#import "WQDir.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQCore.h"
#import "WQAppsSupport.h"
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>

#pragma mark - Apps manager

@interface WQAppItem : NSObject
@property (nonatomic, copy) NSString *container;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) BOOL sizeKnown;
@property (nonatomic) BOOL hasAccess;
@property (nonatomic) BOOL hasIdentity;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic, copy) NSArray<NSDictionary *> *backups;
@end
@implementation WQAppItem
@end

@implementation WQAppsViewController {
    NSArray<WQAppItem *> *_apps;
    NSArray<WQAppItem *> *_visibleApps;
    NSString *_query;
    NSString *_status;
    BOOL _busy;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanning;
    NSArray<NSString *> *_indexTitles;
    NSDictionary<NSString *, NSNumber *> *_indexRows;
}

static NSString *const kWQAppsSortByNamePref = @"WQAppsSortByName";
// 0 all apps, 1 Apple's, 2 everyone else's, 3 apps with a backup.
static NSString *const kWQAppsFilterPref = @"WQAppsFilter";

static BOOL wq_app_is_apple(WQAppItem *app)
{
    return [app.bundleID hasPrefix:@"com.apple."];
}

static NSString *wq_apps_index_letter(NSString *name)
{
    if (!name.length) return @"#";
    NSString *first = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
                       stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil].uppercaseString;
    unichar c = first.length ? [first characterAtIndex:0] : 0;
    return (c >= 'A' && c <= 'Z') ? [NSString stringWithCharacters:&c length:1] : @"#";
}

static NSArray<NSString *> *kAppDataParts(void) { return @[@"Documents", @"Library", @"tmp"]; }
static NSArray<NSString *> *kAppBackupParts(void) { return @[@"Documents", @"Library"]; }

static NSString *wq_app_backup_root_for_bundle(NSString *bundleID)
{
    if (!WQAppsSupportBundleIDValid(bundleID)) return nil;
    return [wq_app_backup_root() stringByAppendingPathComponent:bundleID];
}

// An app backup is AppBackups/<bundle id>/<date>/{Documents,Library} plus a
// manifest. It is built in a hidden staging folder and only renamed into
// place, with the manifest, once every file was copied: a failed or
// interrupted backup never shows up as one that can be restored.
static NSString *const kBackupManifest = @".wqbackup.plist";
static NSString *const kBackupStagingPrefix = @".incomplete-";
static NSString *const kBackupReasonBeforeRestore = @"Before restore";

static NSDictionary *wq_backup_manifest(NSString *backup)
{
    struct stat st;
    NSString *path = [backup stringByAppendingPathComponent:kBackupManifest];
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return nil;
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:path];
    return [manifest isKindOfClass:NSDictionary.class] ? manifest : nil;
}

static BOOL wq_backup_root_child(NSString *path, NSString *bundleID)
{
    NSString *root = [wq_app_backup_root_for_bundle(bundleID) stringByStandardizingPath];
    if (!root.length) return NO;
    NSString *parent = [path.stringByDeletingLastPathComponent stringByStandardizingPath];
    NSString *name = path.lastPathComponent;
    return [parent isEqualToString:root] && name.length && ![name hasPrefix:@"."];
}

static BOOL wq_backup_parts_on_disk(NSString *backup, NSArray<NSString *> *expectedParts,
                                    BOOL hasManifest, NSString **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listError = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:backup error:&listError];
    if (!children) {
        if (error) *error = listError.localizedDescription ?: @"The backup folder cannot be read";
        return NO;
    }
    NSMutableSet *actual = [NSMutableSet set];
    for (NSString *name in children) {
        if (hasManifest && [name isEqualToString:kBackupManifest]) continue;
        if (![(@[@"Documents", @"Library"]) containsObject:name]) {
            if (error) *error = [NSString stringWithFormat:@"The backup contains an unexpected item: %@", name];
            return NO;
        }
        NSString *part = [backup stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(part.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
            if (error) *error = [NSString stringWithFormat:@"The backup part %@ is not a directory", name];
            return NO;
        }
        NSError *partError = nil;
        if (![fm contentsOfDirectoryAtPath:part error:&partError]) {
            if (error) *error = [NSString stringWithFormat:@"The backup part %@ cannot be read: %@", name,
                                 partError.localizedDescription ?: @"未知错误"];
            return NO;
        }
        [actual addObject:name];
    }
    if (![actual isEqualToSet:[NSSet setWithArray:expectedParts]]) {
        if (error) *error = @"备份清单与磁盘上的部分不匹配";
        return NO;
    }
    return YES;
}

// Strict validation is used for current backups and recovery material. A
// no-manifest directory is accepted only as an explicitly unverified legacy
// backup; it never supplies implicit purge instructions for recovery.
static BOOL wq_validate_backup(NSString *backup, NSString *bundleID, BOOL allowLegacy,
                               NSArray<NSString *> **partsOut, NSDictionary **manifestOut,
                               BOOL *verifiedOut, NSString **error)
{
    if (!wq_backup_root_child(backup, bundleID)) {
        if (error) *error = @"备份路径不在该应用的备份文件夹内";
        return NO;
    }
    struct stat backupStat;
    if (lstat(backup.fileSystemRepresentation, &backupStat) != 0 || !S_ISDIR(backupStat.st_mode)) {
        if (error) *error = @"备份文件夹缺失";
        return NO;
    }
    NSString *manifestPath = [backup stringByAppendingPathComponent:kBackupManifest];
    struct stat manifestStat;
    int manifestResult = lstat(manifestPath.fileSystemRepresentation, &manifestStat);
    if (manifestResult != 0 && errno != ENOENT) {
        if (error) *error = [NSString stringWithFormat:@"Cannot inspect the backup manifest (errno %d)", errno];
        return NO;
    }
    BOOL hasManifest = manifestResult == 0;
    if (hasManifest && !S_ISREG(manifestStat.st_mode)) {
        if (error) *error = @"备份清单不是常规文件";
        return NO;
    }
    NSDictionary *manifest = hasManifest ? wq_backup_manifest(backup) : nil;
    NSArray<NSString *> *parts = nil;
    BOOL verified = NO;
    if (hasManifest) {
        NSString *manifestError = nil;
        if (!WQAppsSupportManifestFields(manifest, bundleID, &parts, &manifestError)) {
            if (error) *error = manifestError ?: @"The backup manifest is invalid";
            return NO;
        }
        verified = YES;
    } else {
        if (!allowLegacy) {
            if (error) *error = @"安全备份没有类型化清单";
            return NO;
        }
        NSMutableArray *legacyParts = [NSMutableArray new];
        NSError *listError = nil;
        NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:backup error:&listError];
        if (!children) {
            if (error) *error = listError.localizedDescription ?: @"The legacy backup cannot be read";
            return NO;
        }
        for (NSString *name in children) {
            if (![(@[@"Documents", @"Library"]) containsObject:name]) {
                if (error) *error = [NSString stringWithFormat:@"The legacy backup contains an unexpected item: %@", name];
                return NO;
            }
            [legacyParts addObject:name];
        }
        parts = [legacyParts sortedArrayUsingSelector:@selector(compare:)];
    }
    if (!wq_backup_parts_on_disk(backup, parts, hasManifest, error)) return NO;
    if (partsOut) *partsOut = parts;
    if (manifestOut) *manifestOut = manifest;
    if (verifiedOut) *verifiedOut = verified;
    return YES;
}

// Newest first. Current backups are ordered by their manifest timestamp and
// numeric collision sequence, never by the display name's text ordering.
static NSArray<NSDictionary *> *wq_app_backups(NSString *bundleID)
{
    NSString *root = wq_app_backup_root_for_bundle(bundleID);
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [root stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        NSString *validationError = nil;
        NSArray *parts = nil;
        NSDictionary *manifest = nil;
        BOOL verified = NO;
        BOOL valid = wq_validate_backup(path, bundleID, YES, &parts, &manifest, &verified, &validationError);
        BOOL hasManifest = lstat([[path stringByAppendingPathComponent:kBackupManifest] fileSystemRepresentation], &st) == 0;
        if (!valid && !hasManifest) continue;
        NSDate *created = [manifest[@"Created"] isKindOfClass:NSDate.class] ? manifest[@"Created"] :
            [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        NSUInteger sequence = WQAppsSupportBackupSequence(name);
        if (WQAppsSupportIsInteger(manifest[@"Sequence"]) && [manifest[@"Sequence"] unsignedIntegerValue])
            sequence = [manifest[@"Sequence"] unsignedIntegerValue];
        [out addObject:@{ @"path": path, @"name": name, @"verified": @(valid && verified),
                          @"reason": valid ? (manifest[@"Reason"] ?: @"") : (validationError ?: @"清单无效"),
                          @"created": created, @"sequence": @(sequence) }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return WQAppsSupportCompareBackupMetadata(b[@"created"], [b[@"sequence"] unsignedIntegerValue], b[@"name"],
                                                    a[@"created"], [a[@"sequence"] unsignedIntegerValue], a[@"name"]);
    }];
    return out;
}

static NSString *wq_backup_label(NSDictionary *__unused backup)
{
    NSString *label = backup[@"name"];
    if ([backup[@"reason"] length]) label = [label stringByAppendingFormat:@" (%@)", [backup[@"reason"] lowercaseString]];
    if (![backup[@"verified"] boolValue]) label = [label stringByAppendingString:@"（较旧，未验证）"];
    return label;
}

static BOOL wq_validate_container(NSString *container, NSString *bundleID, dev_t expectedDevice,
                                  ino_t expectedInode, NSString **error)
{
    struct stat st;
    if (lstat(container.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
        if (error) *error = @"应用容器已不存在或不是目录";
        return NO;
    }
    if (expectedDevice && expectedInode && (st.st_dev != expectedDevice || st.st_ino != expectedInode)) {
        if (error) *error = @"应用容器在扫描后已被替换";
        return NO;
    }
    NSString *label = wq_container_label(container);
    if (!label.length || ![label isEqualToString:bundleID]) {
        if (error) *error = @"应用容器身份与所选应用不再匹配";
        return NO;
    }
    return YES;
}

static BOOL wq_copy_part_and_verify(NSString *src, NSString *dst, NSString **error)
{
    BOOL sourceBeforeExists = NO;
    NSString *sourceBefore = WQAppsSupportTreeSignature(src, YES, &sourceBeforeExists, error);
    if (!sourceBefore) return NO;
    if (!wq_copy_contents(src, dst, error)) return NO;
    BOOL srcExists = NO, dstExists = NO;
    NSString *sourceAfter = WQAppsSupportTreeSignature(src, YES, &srcExists, error);
    NSString *sourceShape = WQAppsSupportTreeSignature(src, NO, NULL, error);
    NSString *destinationShape = WQAppsSupportTreeSignature(dst, NO, &dstExists, error);
    if (!sourceAfter || !sourceShape || !destinationShape || !sourceBeforeExists || !srcExists || !dstExists ||
        ![sourceBefore isEqualToString:sourceAfter] ||
        ![sourceShape isEqualToString:destinationShape]) {
        if (error && !*error) *error = @"无法验证复制的树（源已更改或复制不完整）";
        return NO;
    }
    return YES;
}

static BOOL wq_purge_and_verify(NSString *dir, unsigned long long *freed, NSString **error)
{
    if (!wq_purge_contents(dir, freed)) return NO;
    struct stat st;
    if (!wq_stat(dir, &st)) return YES;   // a missing part is an acceptable empty result
    if (!S_ISDIR(st.st_mode)) {
        if (error) *error = [NSString stringWithFormat:@"%@ is not a directory", dir.lastPathComponent];
        return NO;
    }
    NSError *listError = nil;
    NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:&listError];
    if (!remaining) {
        if (error) *error = listError.localizedDescription ?: [NSString stringWithFormat:@"Cannot read %@", dir.lastPathComponent];
        return NO;
    }
    if (remaining.count) {
        if (error) *error = [NSString stringWithFormat:@"Some items remain in %@; keep the app closed and try again", dir.lastPathComponent];
        return NO;
    }
    return YES;
}

// Copies the app's Documents and Library into a new complete backup. Returns
// its path, or nil with *error (nothing is left behind then).
static NSString *wq_make_app_backup(NSString *bundleID, NSString *container, dev_t expectedDevice,
                                    ino_t expectedInode, NSString *reason, NSString **error)
{
    if (!WQAppsSupportBundleIDValid(bundleID)) {
        if (error) *error = @"应用标识符不是有效的 Bundle ID";
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!wq_validate_container(container, bundleID, expectedDevice, expectedInode, error)) return nil;
    NSString *root = wq_app_backup_root_for_bundle(bundleID);
    if (!root.length) {
        if (error) *error = @"无法找到应用备份文件夹";
        return nil;
    }
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil])   // leftovers of interrupted runs
        if ([name hasPrefix:kBackupStagingPrefix]) [fm removeItemAtPath:[root stringByAppendingPathComponent:name] error:nil];

    NSString *staging = [root stringByAppendingPathComponent:
                         [kBackupStagingPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:nil]) {
        if (error) *error = @"无法创建备份文件夹";
        return nil;
    }
    NSMutableArray *parts = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSString *> *sourceStates = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *partHashes = [NSMutableDictionary new];
    BOOL ok = YES;
    for (NSString *part in kAppBackupParts()) {
        NSString *src = [container stringByAppendingPathComponent:part];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0 && errno == ENOENT) continue;   // the app has none
        if (!wq_stat(src, &st)) { ok = NO; if (error) *error = [NSString stringWithFormat:@"Cannot access %@", part]; break; }
        BOOL sourceExists = NO;
        NSString *sourceState = WQAppsSupportTreeSignature(src, YES, &sourceExists, error);
        if (!sourceState) { ok = NO; break; }
        sourceStates[part] = sourceState;
        NSString *stagedPart = [staging stringByAppendingPathComponent:part];
        if (!wq_copy_part_and_verify(src, stagedPart, error)) { ok = NO; break; }
        BOOL stagedExists = NO;
        NSString *contentHash = WQAppsSupportTreeContentSignature(stagedPart, &stagedExists, error);
        if (!contentHash || !stagedExists) {
            ok = NO;
            if (error && !*error) *error = @"无法计算暂存备份部分的哈希";
            break;
        }
        partHashes[part] = contentHash;
        [parts addObject:part];
    }
    if (ok) {
        for (NSString *part in kAppBackupParts()) {
            NSString *src = [container stringByAppendingPathComponent:part];
            BOOL sourceExists = NO;
            NSString *sourceState = WQAppsSupportTreeSignature(src, YES, &sourceExists, error);
            NSString *before = sourceStates[part] ?: @"<missing>";
            if (!sourceState || ![before isEqualToString:sourceState]) {
                ok = NO;
                if (error && !*error) *error = @"应用数据在备份期间已更改；未生成快照一致的副本";
                break;
            }
        }
    }
    NSDate *created = NSDate.date;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *stamp = [fmt stringFromDate:created];
    NSString *final = [root stringByAppendingPathComponent:stamp];
    NSUInteger sequence = 1;
    for (NSUInteger n = 2; [fm fileExistsAtPath:final]; n++) {
        sequence = n;
        final = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%lu)", stamp, (unsigned long)n]];
    }
    NSDictionary *manifest = @{ @"Complete": @YES, @"BundleID": bundleID, @"Created": created,
                                @"Parts": parts, @"PartHashes": partHashes,
                                @"Reason": reason ?: @"", @"Format": @1,
                                @"Sequence": @(sequence) };
    if (ok && ![manifest writeToFile:[staging stringByAppendingPathComponent:kBackupManifest] atomically:YES]) {
        ok = NO;
        if (error) *error = @"无法写入备份清单";
    }
    BOOL published = NO;
    if (ok) {
        if (!wq_validate_container(container, bundleID, expectedDevice, expectedInode, error)) ok = NO;
    }
    if (ok) {
        if (rename(staging.fileSystemRepresentation, final.fileSystemRepresentation) != 0) {
            ok = NO;
            if (error) *error = [NSString stringWithFormat:@"无法完成备份（errno %d）", errno];
        } else {
            published = YES;
            NSString *validationError = nil;
            if (!wq_validate_backup(final, bundleID, NO, NULL, NULL, NULL, &validationError) ||
                !wq_validate_container(container, bundleID, expectedDevice, expectedInode, &validationError)) {
                ok = NO;
                if (error) *error = validationError ?: @"应用容器在备份完成期间已更改";
            }
        }
    }
    if (!ok) {
        [fm removeItemAtPath:published ? final : staging error:nil];
        wq_log(@"app backup %@: FAILED (%@)", bundleID, error && *error ? *error : @"?");
        return nil;
    }
    wq_log(@"app backup %@ -> %@ (%@)", bundleID, final.lastPathComponent, [parts componentsJoinedByString:@", "]);
    return final;
}

static BOOL wq_dir_size_cancellable(NSString *dir, WQScanCancellation *cancellation,
                                     unsigned long long *sizeOut, BOOL *completeOut)
{
    if (completeOut) *completeOut = NO;
    if (sizeOut) *sizeOut = 0;
    if (cancellation.isCancelled) return NO;
    // Items 1-2: a fresh cached measurement (shared with the Cache screen)
    // costs one lstat, not a tree traversal. A stale entry is re-measured
    // by this background scan; a missing or changed container is measured
    // once, with subtotals, and stored for both screens. Limited means
    // some subtree could not be read, as before.
    WQTreeSubtotals sub = {0};
    BOOL cachedLimited = NO, cachedStale = NO;
    if (wq_container_size_lookup(dir, &sub, &cachedLimited, &cachedStale) && !cachedStale) {
        if (sizeOut) *sizeOut = sub.total;
        if (completeOut) *completeOut = !cachedLimited;
        return YES;
    }
    WQMeasureResult result = wq_measure_tree_subtotals(dir, cancellation, &sub);
    if (result == WQMeasureResultCancelled) return NO;
    if (result == WQMeasureResultMissing) {
        if (sizeOut) *sizeOut = 0;
        if (completeOut) *completeOut = YES;
        return YES;
    }
    BOOL limited = result == WQMeasureResultLimited;
    wq_container_size_store(dir, &sub, limited);
    if (sizeOut) *sizeOut = sub.total;
    if (completeOut) *completeOut = !limited;
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"应用";
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用";
    self.navigationItem.rightBarButtonItem = [self sortButton];
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.tableView.tableHeaderView = wq_device_header(self.view.bounds.size.width);
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    [self scan];
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_container_size_invalidate_all();
    wq_display_names_reset_miss();
    [self scan];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_scanning && _scanCancellation.isCancelled) [self scan];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // Leaving the page no longer cancels the apps scan: the scan is owned
    // by the operation (shared keep-alive + scan-cache checkpoint), not by
    // this screen, so switching apps or locking the screen does not restart
    // it from scratch. Only an explicit new scan supersedes it.
}

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    _busy = busy;
    _status = status;
    [self.tableView reloadData];
}

// Watchdog for the app scan: each step records what it's doing; a timer logs
// any step that stays unchanged for 10 s, so a hang shows up in the Log.
static NSObject *gAppScanStepLock;
static NSString *gAppScanStep;
static CFAbsoluteTime gAppScanStepAt;
static NSUInteger gAppScanStepSerial;

static void WQAppScanStep(NSString *step)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gAppScanStepLock = [NSObject new]; });
    @synchronized (gAppScanStepLock) {
        gAppScanStep = [step copy];
        gAppScanStepAt = CFAbsoluteTimeGetCurrent();
        gAppScanStepSerial++;
    }
}

static void WQAppScanWatch(WQScanCancellation *cancellation, NSUInteger lastSerial, NSUInteger reported)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *step = nil;
        NSUInteger serial = 0;
        double age = 0;
        @synchronized (gAppScanStepLock) {
            step = gAppScanStep;
            serial = gAppScanStepSerial;
            age = CFAbsoluteTimeGetCurrent() - gAppScanStepAt;
        }
        if (!step) return;   // scan finished
        NSUInteger nowReported = serial == lastSerial ? reported : 0;
        if (age >= 10 && nowReported < 6) {
            wq_log(@"app scan: still %@ after %.0f s%@", step, age, cancellation.isCancelled ? @" (screen left)" : @"");
            nowReported++;
        }
        WQAppScanWatch(cancellation, serial, nowReported);
    });
}

- (void)scan
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    [self setBusy:YES status:@"正在查找应用…"];
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    WQAppScanStep(@"finding app containers");
    WQAppScanWatch(cancellation, 0, 0);
    dispatch_async(wq_io_scan(), ^{
        CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
        NSArray *containers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, cancellation,
            ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_status = [NSString stringWithFormat:@"正在查找应用… %lld%%", total ? (long long)(done * 100 / total) : 0];
                    [self.tableView reloadData];
                });
            });
        if (!cancellation.isCancelled && !wq_display_names_loaded()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_status = @"正在读取应用名称…";
                [self.tableView reloadData];
            });
            WQAppScanStep(@"reading app names");
            CFAbsoluteTime namesStarted = CFAbsoluteTimeGetCurrent();
            wq_load_display_names();
            wq_log(@"app scan: app names %@ in %.1f s", wq_display_names_loaded() ? @"loaded" : @"not loaded",
                   CFAbsoluteTimeGetCurrent() - namesStarted);
        }
        if (containers) wq_log(@"app scan: %lu containers found in %.1f s; measuring", (unsigned long)containers.count,
                               CFAbsoluteTimeGetCurrent() - scanStarted);
        if (!containers && !cancellation.isCancelled) wq_log(@"app scan: container enumeration failed; see the preceding enumerate log");
        else if (containers && containers.count == 0) wq_log(@"app scan: enumeration returned no container paths; check the base path and inode bound");
        NSMutableArray<WQAppItem *> *apps = [NSMutableArray new];
        NSMutableArray<NSString *> *refused = [NSMutableArray new];
        NSUInteger i = 0, missingLabels = 0, limited = 0, sizeLimited = 0;
        for (NSString *c in containers) {
            if (cancellation.isCancelled) { WQAppScanStep(nil); return; }
            i++;
            if ([[c stringByResolvingSymlinksInPath] isEqualToString:home]) continue;  // ourselves
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_status = [NSString stringWithFormat:@"正在测量 %lu/%lu…", (unsigned long)i, (unsigned long)containers.count];
                [self.tableView reloadData];
            });
            NSString *shortName = c.lastPathComponent;
            WQAppScanStep([NSString stringWithFormat:@"getting access to %@ (%lu/%lu)", shortName, (unsigned long)i, (unsigned long)containers.count]);
            BOOL granted = wq_grant(c);
            if (!granted) {
                [refused addObject:[NSString stringWithFormat:@"%@ (%@)", c.lastPathComponent,
                                    wq_bundle_id_for_container(c) ?: @"unknown app"]];
            }
            WQAppScanStep([NSString stringWithFormat:@"reading the identifier of %@", shortName]);
            NSString *bid = wq_container_label(c);
            if (!bid.length) {
                missingLabels++;
                if (missingLabels <= 3) wq_log(@"app scan: no container identifier for %@", c);
            }
            struct stat identity;
            BOOL validBundle = WQAppsSupportBundleIDValid(bid);
            BOOL hasIdentity = validBundle && wq_stat(c, &identity) && S_ISDIR(identity.st_mode);
            if (!granted || !validBundle || !hasIdentity) limited++;
            WQAppItem *app = [WQAppItem new];
            app.container = c;
            app.bundleID = bid;
            app.hasAccess = granted;
            app.hasIdentity = hasIdentity;
            app.containerDevice = hasIdentity ? identity.st_dev : 0;
            app.containerInode = hasIdentity ? identity.st_ino : 0;
            if (bid.length) (void)wq_app_icon(bid);   // warm the icon off the main thread
            app.name = bid.length ? (wq_display_name(bid) ?: bid)
                                  : [NSString stringWithFormat:@"未知容器（%@）", c.lastPathComponent];
            app.bytes = 0;
            app.sizeKnown = NO;
            unsigned long long appSize = 0;
            BOOL sizeKnown = NO;
            WQAppScanStep([NSString stringWithFormat:@"measuring %@ (%@)", shortName, bid ?: @"no identifier"]);
            if (granted && hasIdentity && !wq_dir_size_cancellable(c, cancellation, &appSize, &sizeKnown)) { WQAppScanStep(nil); return; }
            app.bytes = appSize;
            app.sizeKnown = sizeKnown;
            if (granted && hasIdentity && !sizeKnown) sizeLimited++;
            app.backups = bid.length ? wq_app_backups(bid) : @[];
            [apps addObject:app];
        }
        WQAppScanStep(nil);
        if (cancellation.isCancelled) return;
        wq_log(@"app scan: %lu apps measured in %.1f s", (unsigned long)apps.count, CFAbsoluteTimeGetCurrent() - scanStarted);
        if (refused.count) wq_log(@"app scan: %lu containers refused access: %@", (unsigned long)refused.count,
                                  [refused componentsJoinedByString:@", "]);
        [apps sortUsingComparator:^NSComparisonResult(WQAppItem *a, WQAppItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSString *note = nil;
        if (!wq_app_group()) note = @"WQ Files 没有 App Group，因此无法打开其他应用的文件夹。请使用保留 App Group 的工具重新签名（见 README 中的 Signing）。";
        else if (!containers && wq_full_scan_was_declined()) note = @"应用尚未列出：需要扫描全部文件。下拉即可开始。";
        else if (!containers) note = @"容器枚举失败。请查看日志了解 statfs/inode 原因。";
        else if (!containers.count) note = @"未找到应用容器。请刷新，并查看日志了解枚举原因。";
        else if (limited || sizeLimited) note = [NSString stringWithFormat:@"%lu 个容器 · 其中 %lu 个访问、身份、大小受限或没有标识符。请查看日志。",
                                                 (unsigned long)apps.count, (unsigned long)(limited + sizeLimited)];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration || cancellation.isCancelled) return;
            self->_scanning = NO;
            self->_apps = apps;
            [self rebuildVisibleApps];
            [self.refreshControl endRefreshing];
            [self setBusy:NO status:note];
        });
    });
}

- (NSArray<WQAppItem *> *)visibleApps
{
    return _visibleApps ?: @[];
}

- (void)rebuildVisibleApps
{
    NSArray<WQAppItem *> *shown = _apps ?: @[];
    NSInteger filter = [NSUserDefaults.standardUserDefaults integerForKey:kWQAppsFilterPref];
    if (filter > 0) {
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *__unused b) {
            if (filter == 1) return wq_app_is_apple(a);
            if (filter == 2) return !wq_app_is_apple(a);
            return a.backups.count > 0;
        }]];
    }
    if (_query.length) {
        shown = [shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQAppItem *a, NSDictionary *__unused b) {
            return [a.name localizedCaseInsensitiveContainsString:self->_query] ||
                   [a.bundleID localizedCaseInsensitiveContainsString:self->_query];
        }]];
    }
    BOOL byName = [NSUserDefaults.standardUserDefaults boolForKey:kWQAppsSortByNamePref];
    _visibleApps = [shown sortedArrayUsingComparator:^NSComparisonResult(WQAppItem *a, WQAppItem *b) {
        NSComparisonResult names = [(a.name ?: @"") localizedStandardCompare:(b.name ?: @"")];
        if (byName || a.bytes == b.bytes) return names;
        return a.bytes > b.bytes ? NSOrderedAscending : NSOrderedDescending;
    }];
    // Alphabet sidebar when sorted by name.
    NSMutableArray *titles = [NSMutableArray new];
    NSMutableDictionary *rows = [NSMutableDictionary new];
    if (byName && _visibleApps.count >= 25) {
        [_visibleApps enumerateObjectsUsingBlock:^(WQAppItem *app, NSUInteger row, BOOL *__unused stop) {
            NSString *letter = wq_apps_index_letter(app.name);
            if (!rows[letter]) { rows[letter] = @(row); [titles addObject:letter]; }
        }];
    }
    _indexTitles = titles.count > 1 ? titles : nil;
    _indexRows = rows;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return (_busy && !_apps.count) ? nil : _indexTitles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index
{
    NSNumber *row = _indexRows[title];
    if (row && row.unsignedIntegerValue < self.visibleApps.count)
        [tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row.integerValue inSection:0]
                         atScrollPosition:UITableViewScrollPositionTop animated:NO];
    return -1;   // already scrolled to the row; the list has one section
}

- (UIBarButtonItem *)sortButton
{
    __weak typeof(self) weakSelf = self;
    UIDeferredMenuElement *items = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        BOOL byName = [NSUserDefaults.standardUserDefaults boolForKey:kWQAppsSortByNamePref];
        UIAction *size = [UIAction actionWithTitle:@"大小" image:nil identifier:nil handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:kWQAppsSortByNamePref];
            [weakSelf resortApps];
        }];
        UIAction *name = [UIAction actionWithTitle:@"名称" image:nil identifier:nil handler:^(UIAction *__unused a) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:kWQAppsSortByNamePref];
            [weakSelf resortApps];
        }];
        size.state = byName ? UIMenuElementStateOff : UIMenuElementStateOn;
        name.state = byName ? UIMenuElementStateOn : UIMenuElementStateOff;
        size.subtitle = @"从大到小";
        name.subtitle = @"A–Z";
        UIMenu *sort = [UIMenu menuWithTitle:@"排序方式" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[size, name]];
        NSInteger current = [NSUserDefaults.standardUserDefaults integerForKey:kWQAppsFilterPref];
        NSArray *titles = @[@"全部应用", @"Apple 应用", @"其他应用", @"已备份"];
        NSMutableArray *filters = [NSMutableArray new];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            UIAction *f = [UIAction actionWithTitle:titles[(NSUInteger)i] image:nil identifier:nil handler:^(UIAction *__unused a) {
                [NSUserDefaults.standardUserDefaults setInteger:i forKey:kWQAppsFilterPref];
                [weakSelf resortApps];
            }];
            f.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [filters addObject:f];
        }
        UIMenu *show = [UIMenu menuWithTitle:@"显示" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:filters];
        completion(@[sort, show]);
    }];
    return [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
                                             menu:[UIMenu menuWithChildren:@[items]]];
}

- (void)resortApps
{
    [self rebuildVisibleApps];
    [self.tableView reloadData];
    [self.tableView reloadSectionIndexTitles];
}

// Long-press: copy the bundle ID or container path, open the data folder.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (_busy || (NSUInteger)indexPath.row >= self.visibleApps.count) return nil;
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (app.bundleID.length) {
            [actions addObject:[UIAction actionWithTitle:@"复制 Bundle ID" image:[UIImage systemImageNamed:@"tag"] identifier:nil
                                                  handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = app.bundleID; }]];
        }
        [actions addObject:[UIAction actionWithTitle:@"复制容器路径" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                                              handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = app.container; }]];
        if (app.hasAccess) {
            [actions addObject:[UIAction actionWithTitle:@"打开数据文件夹" image:[UIImage systemImageNamed:@"folder"] identifier:nil
                                                  handler:^(UIAction *__unused a) {
                [weakSelf.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name]
                                                         animated:YES];
            }]];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleApps];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (_busy && !_apps.count) ? 1 : (NSInteger)self.visibleApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_status) return _status;
    unsigned long long total = 0;
    for (WQAppItem *a in _apps) total += a.bytes;
    if (_query.length || [NSUserDefaults.standardUserDefaults integerForKey:kWQAppsFilterPref] > 0)
        return [NSString stringWithFormat:@"%lu/%lu 个应用", (unsigned long)self.visibleApps.count, (unsigned long)_apps.count];
    return [NSString stringWithFormat:@"%lu 个应用 · 应用数据 %@", (unsigned long)_apps.count, wq_size_text(total)];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"Tap an app to back up, restore or clear its Documents and Library. Close the app first (swipe it away in the app switcher); operations are not snapshot-consistent while it runs. "
            "Backups are stored in WQFiles/AppBackups and are visible in the Files app. tmp is cleared when requested but is not backed up or restored.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_busy && !_apps.count) {
        c.text = @"正在扫描…";
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    c.text = app.name;
    NSString *identifier = app.bundleID.length ? app.bundleID : app.container.lastPathComponent;
    BOOL hasBackup = app.backups.count > 0;
    if (!app.hasAccess) {
        c.secondaryText = [NSString stringWithFormat:@"无法访问 · %@", identifier];
    } else if (!app.bundleID.length) {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@ · 无标识符", wq_size_text(app.bytes), identifier];
    } else if (!app.hasIdentity) {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@ · 容器身份不可用", wq_size_text(app.bytes), app.bundleID];
    } else if (!app.sizeKnown) {
        c.secondaryText = [NSString stringWithFormat:@"大小不可用 · %@%@", app.bundleID, hasBackup ? @" · 已备份" : @""];
    } else {
        c.secondaryText = [NSString stringWithFormat:@"%@ · %@%@", wq_size_text(app.bytes), app.bundleID, hasBackup ? @" · 已备份" : @""];
    }
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.image = wq_app_icon(app.bundleID) ?: [UIImage systemImageNamed:@"app.dashed"];
    c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy || !self.visibleApps.count) return;
    WQAppItem *app = self.visibleApps[(NSUInteger)indexPath.row];
    if (!app.hasAccess || !app.bundleID.length || !app.hasIdentity) {
        NSString *why = app.hasAccess && app.bundleID.length && !app.hasIdentity
            ? @"容器身份不可用或已更改。此条目的备份、恢复和清除功能已禁用。"
            : app.hasAccess
            ? @"容器标识符不可用。此条目的备份、恢复和清除功能已禁用。"
            : @"沙盒访问不可用。请检查 App Group 并查看日志；只能复制容器路径。";
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app.name
            message:[NSString stringWithFormat:@"%@\n\n%@", app.container, why]
            preferredStyle:UIAlertControllerStyleActionSheet];
        if (app.hasAccess) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"打开数据文件夹" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name] animated:YES];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"复制容器路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            UIPasteboard.generalPasteboard.string = app.container;
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app.name
        message:[NSString stringWithFormat:@"%@\n%@", app.bundleID,
                 app.sizeKnown ? [NSString stringWithFormat:@"%@ 数据", wq_size_text(app.bytes)] : @"大小不可用"]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"备份数据" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [self backUp:app then:nil];
    }]];
    NSArray *backups = app.backups;
    NSString *latest = backups.firstObject[@"path"];
    if (latest) {
        NSString *title = backups.count == 1 ? [NSString stringWithFormat:@"恢复备份（%@）", wq_backup_label(backups.firstObject)]
                                             : [NSString stringWithFormat:@"恢复备份…（%lu 个）", (unsigned long)backups.count];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            [self pickBackupToRestore:app from:[tableView cellForRowAtIndexPath:indexPath]];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"分享最新备份（隔空投送…）"
                                                  style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
            UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
            wq_share_folder(self, latest, [NSString stringWithFormat:@"%@ %@", app.name, latest.lastPathComponent], c);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"清除数据…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self confirmClear:app];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"打开数据文件夹" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:app.container title:app.name] animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制 Bundle ID" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        UIPasteboard.generalPasteboard.string = app.bundleID;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)finish:(NSString *)title message:(NSString *)message
{
    [self setBusy:NO status:nil];
    wq_alert(self, title, message);
    [self scan];
}

- (void)backUp:(WQAppItem *)app then:(void (^)(BOOL ok))next
{
    [self setBusy:YES status:[NSString stringWithFormat:@"正在备份 %@…", app.name]];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSString *dest = wq_make_app_backup(app.bundleID, app.container, app.containerDevice,
                                             app.containerInode, nil, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (next) { next(dest != nil); return; }
            [self finish:dest ? @"已备份" : @"备份失败"
                 message:dest ? [NSString stringWithFormat:@"已保存到 AppBackups/%@/%@", app.bundleID, dest.lastPathComponent]
                              : [NSString stringWithFormat:@"未保存任何内容：%@", error ?: @"见日志"]];
        });
    });
}

- (void)clear:(WQAppItem *)app
{
    [self setBusy:YES status:[NSString stringWithFormat:@"正在清除 %@…", app.name]];
    dispatch_async(wq_io(), ^{
        unsigned long long freed = 0;
        NSString *error = nil;
        BOOL ok = wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error);
        for (NSString *part in kAppDataParts()) {
            if (!ok) break;
            if (!wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error) ||
                !wq_purge_and_verify([app.container stringByAppendingPathComponent:part], &freed, &error)) ok = NO;
        }
        if (ok && !wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) ok = NO;
        // Purging changes the container below its root, which the size
        // cache's root-mtime check cannot see: drop the entry so the
        // rescan in finish: measures the emptied container.
        wq_container_size_invalidate(app.container);
        wq_log(@"clear data: %@ freed %llu ok=%d", app.bundleID, freed, ok);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finish:ok ? @"数据已清除" : @"部分清除"
                 message:[NSString stringWithFormat:@"已释放约 %@。%@请打开 %@ 以全新开始。", wq_size_text(freed),
                          ok ? @"" : [NSString stringWithFormat:@" %@。请保持该应用关闭，然后重试。", error ?: @"有些项目无法删除（见日志）"], app.name]];
        });
    });
}

- (void)confirmClear:(WQAppItem *)app
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"清除 %@？", app.name]
        message:@"会删除该应用的 Documents、Library 和 tmp 中的全部内容，如同全新安装。"
                "可选备份仅涵盖 Documents 和 Library；tmp 会被丢弃且无法恢复。"
                "登录信息、设置和离线内容将会丢失。请先关闭该应用。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"先备份再清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self backUp:app then:^(BOOL ok) {
            if (ok) [self clear:app];
            else [self finish:@"未清除" message:@"备份未完成，因此未删除任何内容。"];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"不备份直接清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self clear:app];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pickBackupToRestore:(WQAppItem *)app from:(UIView *)source
{
    NSArray *backups = app.backups;
    if (backups.count == 1) { [self confirmRestore:app from:backups.firstObject]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"恢复哪个备份？" message:app.name
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *__unused b in backups) {
        [sheet addAction:[UIAlertAction actionWithTitle:wq_backup_label(b) style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused a) { [self confirmRestore:app from:b]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = (source ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRestore:(WQAppItem *)app from:(NSDictionary *)backup
{
    NSString *path = backup[@"path"];
    NSString *warning = [backup[@"verified"] boolValue] ? @""
        : [NSString stringWithFormat:@"\n\n此备份未经验证（%@）。WQ Files 在更改任何内容前会重新检查其各部分。",
           backup[@"reason"] ?: @"没有清单"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"恢复 %@？", app.name]
        message:[NSString stringWithFormat:@"将用 %@ 的备份替换该应用当前的 Documents 和 Library；tmp 不动。"
                 "当前数据会先备份，出错时再还原。请先关闭该应用：运行中的应用可能导致操作无法保持快照一致。%@",
                 wq_backup_label(backup), warning]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self setBusy:YES status:[NSString stringWithFormat:@"正在恢复 %@…", app.name]];
        dispatch_async(wq_io(), ^{
            NSString *title = nil, *message = nil;
            [self restore:app from:path title:&title message:&message];
            // Restore replaces the container's parts below its root, which
            // the size cache's root-mtime check cannot see: drop the entry
            // so the rescan in finish: re-measures (on success and on a
            // rollback alike).
            wq_container_size_invalidate(app.container);
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish:title message:message]; });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Best-effort copy of one directory's own xattrs onto another directory.
// Failures are logged, not fatal: no content digest covers directory xattrs.
// Used so a rename of a staged part does not lose the live part dir's own
// attributes, which the old copy-into-it path preserved by never replacing
// the directory itself.
static void wq_copy_dir_xattrs_best_effort(NSString *src, NSString *dst)
{
    ssize_t listSize = listxattr(src.fileSystemRepresentation, NULL, 0, XATTR_NOFOLLOW);
    if (listSize <= 0) return;
    char *list = malloc((size_t)listSize);
    if (!list) return;
    if (listxattr(src.fileSystemRepresentation, list, (size_t)listSize, XATTR_NOFOLLOW) != listSize) {
        free(list);
        return;
    }
    char *cursor = list;
    while (cursor < list + listSize) {
        NSString *name = [NSString stringWithUTF8String:cursor];
        cursor += strlen(cursor) + 1;
        if (!name.length) continue;
        ssize_t valueSize = getxattr(src.fileSystemRepresentation, name.fileSystemRepresentation, NULL, 0, 0, XATTR_NOFOLLOW);
        if (valueSize < 0) {
            wq_log(@"replace: cannot read xattr %@ on %@", name, src.lastPathComponent);
            continue;
        }
        void *value = valueSize ? malloc((size_t)valueSize) : NULL;
        if (valueSize && !value) continue;
        if (getxattr(src.fileSystemRepresentation, name.fileSystemRepresentation, value, (size_t)valueSize, 0, XATTR_NOFOLLOW) != valueSize) {
            wq_log(@"replace: cannot read xattr %@ on %@", name, src.lastPathComponent);
            free(value);
            continue;
        }
        if (setxattr(dst.fileSystemRepresentation, name.fileSystemRepresentation, value, (size_t)valueSize, 0, XATTR_NOFOLLOW) != 0)
            wq_log(@"replace: cannot set xattr %@ on %@", name, dst.lastPathComponent);
        free(value);
    }
    free(list);
}

// Replaces one part (Documents/Library) of the container with `src`.
static BOOL wq_replace_part(NSString *src, NSString *dst, NSString **error)
{
    // Stage the source before purging the live destination. If a named safety
    // part disappears or becomes unreadable, no live data may be purged first.
    NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"WQAppsRestore-%@", NSUUID.UUID.UUIDString]];
    BOOL staged = wq_copy_part_and_verify(src, staging, error);
    if (!staged) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        return NO;
    }
    // The live part dir's own mode survives the old copy-into-it path because
    // the directory itself was never replaced. A rename below does replace
    // it, so remember the mode first. A missing part has no mode to preserve;
    // the staged copy's own mode is then used, as before.
    struct stat dstBefore;
    BOOL dstExisted = lstat(dst.fileSystemRepresentation, &dstBefore) == 0 && S_ISDIR(dstBefore.st_mode);
    mode_t dstMode = dstExisted ? (dstBefore.st_mode & 07777) : 0;
    unsigned long long ignored = 0;
    BOOL ok = wq_purge_and_verify(dst, &ignored, error);
    if (ok) {
        // Item 8: when staging and the destination share a volume, moving
        // the already-verified staged tree into place with one rename
        // replaces the second full copy (plus its four tree signatures).
        // rename(2) is atomic and fails cleanly with staging intact when
        // the volumes differ or the destination is not an empty directory,
        // in which case the old copy path runs unchanged.
        BOOL renamed = NO;
        struct stat stagingStat;
        if (lstat(staging.fileSystemRepresentation, &stagingStat) == 0) {
            struct stat dstStat;
            BOOL dstOnSameVolume;
            if (lstat(dst.fileSystemRepresentation, &dstStat) == 0) {
                dstOnSameVolume = dstStat.st_dev == stagingStat.st_dev;
            } else {
                // The destination was purged away as missing: compare
                // against its parent directory instead.
                struct stat parentStat;
                dstOnSameVolume = lstat(dst.stringByDeletingLastPathComponent.fileSystemRepresentation, &parentStat) == 0 &&
                    parentStat.st_dev == stagingStat.st_dev;
            }
            if (dstOnSameVolume) {
                if (dstExisted) wq_copy_dir_xattrs_best_effort(dst, staging);
                if (rename(staging.fileSystemRepresentation, dst.fileSystemRepresentation) == 0) {
                    renamed = YES;
                    if (dstExisted && chmod(dst.fileSystemRepresentation, dstMode) != 0) {
                        ok = NO;
                        if (error) *error = [NSString stringWithFormat:@"Could not restore %@ (permissions)", dst.lastPathComponent];
                    }
                    int parent = open(dst.stringByDeletingLastPathComponent.fileSystemRepresentation,
                                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                    if (parent >= 0) {
                        if (fsync(parent) != 0) wq_log(@"replace: cannot flush %@", dst.stringByDeletingLastPathComponent);
                        close(parent);
                    }
                }
            }
        }
        if (!renamed && ok) {
            ok = wq_copy_part_and_verify(staging, dst, error);
            if (!ok && error && !*error) *error = [NSString stringWithFormat:@"Could not restore %@", dst.lastPathComponent];
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    return ok;
}

static NSString *wq_restore_journal_path(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"active-restore.plist"];
}

static BOOL wq_read_restore_journal(NSMutableDictionary **journalOut, BOOL *existsOut, NSString **error)
{
    if (journalOut) *journalOut = nil;
    if (existsOut) *existsOut = NO;
    NSString *path = wq_restore_journal_path();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![journal isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"恢复记录无法读取";
        return NO;
    }
    if (existsOut) *existsOut = YES;
    if (journalOut) *journalOut = [journal mutableCopy];
    return YES;
}

static BOOL wq_write_restore_journal(NSDictionary *journal, NSString **error)
{
    NSString *path = wq_restore_journal_path();
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (error) *error = @"无法创建恢复记录文件夹";
        return NO;
    }
    if (![journal writeToFile:path atomically:YES]) {
        if (error) *error = @"无法写入恢复记录";
        return NO;
    }
    return YES;
}

static BOOL wq_remove_restore_journal(NSString **error);

static BOOL wq_begin_restore_journal(WQAppItem *app, NSString *backup, NSString *safety, NSString **error)
{
    if (!wq_backup_root_child(backup, app.bundleID) || !wq_backup_root_child(safety, app.bundleID)) {
        if (error) *error = @"恢复路径不在该应用的备份文件夹内";
        return NO;
    }
    BOOL exists = NO;
    NSMutableDictionary *existing = nil;
    NSString *readError = nil;
    if (!wq_read_restore_journal(&existing, &exists, &readError)) {
        if (error) *error = readError;
        return NO;
    }
    if (exists) {
        WQAppsSupportJournalState state = WQAppsSupportJournalStateForDictionary(existing);
        NSString *policyError = nil;
        if (!WQAppsSupportJournalAllowsNewRestore(state, &policyError)) {
            if (error) *error = policyError;
            return NO;
        }
        if (state == WQAppsSupportJournalCommitted &&
            !wq_remove_restore_journal(&readError)) {
            if (error) *error = readError ?: @"Cannot remove the completed restore journal";
            return NO;
        }
    }
    NSDictionary *journal = @{ @"Format": @2, @"State": @"Active", @"BundleID": app.bundleID,
                               @"Container": app.container, @"Backup": backup, @"Safety": safety,
                               @"ContainerDevice": @(app.containerDevice), @"ContainerInode": @(app.containerInode),
                               @"Started": NSDate.date };
    return wq_write_restore_journal(journal, error);
}

// Marking committed is the point of no return for a completed restore. It is
// deliberately separate from removal: a committed journal must never cause a
// later rollback, even if the file itself cannot be deleted right now.
static BOOL wq_mark_restore_journal_committed(NSString **error)
{
    BOOL exists = NO;
    NSMutableDictionary *journal = nil;
    NSString *readError = nil;
    if (!wq_read_restore_journal(&journal, &exists, &readError)) {
        if (error) *error = readError;
        return NO;
    }
    if (!exists) return YES;
    journal[@"State"] = @"Committed";
    return wq_write_restore_journal(journal, error);
}

static BOOL wq_remove_restore_journal(NSString **error)
{
    NSString *path = wq_restore_journal_path();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return YES;
    NSError *removeError = nil;
    if (![fm removeItemAtPath:path error:&removeError]) {
        if (error) *error = removeError.localizedDescription ?: @"Cannot remove the restore recovery journal";
        return NO;
    }
    return YES;
}

static BOOL wq_finish_restore_journal(NSString **error)
{
    if (!wq_mark_restore_journal_committed(error)) return NO;
    return wq_remove_restore_journal(error);
}

static BOOL wq_validate_backup_hashes(NSString *backup, NSArray<NSString *> *parts,
                                      NSDictionary *manifest, NSString **error)
{
    NSDictionary *hashes = manifest[@"PartHashes"];
    if (!hashes) return YES;   // backups made before content hashes existed
    for (NSString *part in parts) {
        NSString *expected = hashes[part];
        if (![expected isKindOfClass:NSString.class] || !expected.length) {
            if (error) *error = [NSString stringWithFormat:@"The backup has no hash for %@", part];
            return NO;
        }
        BOOL exists = NO;
        NSString *actual = WQAppsSupportTreeContentSignature([backup stringByAppendingPathComponent:part],
                                                              &exists, error);
        if (!actual || !exists || ![actual isEqualToString:expected]) {
            if (error) *error = [NSString stringWithFormat:@"The backup's %@ contents changed after it was created", part];
            return NO;
        }
    }
    return YES;
}

static BOOL wq_rollback_safety(NSString *container, NSString *bundleID, NSString *safety,
                               dev_t expectedDevice, ino_t expectedInode, NSString **error)
{
    NSArray<NSString *> *parts = nil;
    NSDictionary *safetyManifest = nil;
    // Validate everything immediately before the first mutation. In
    // particular, a missing named safety part is never interpreted as an
    // instruction to purge the live part. (This used to run the same three
    // checks twice in a row — the second copy validated nothing new, since
    // no mutation happens between the two — so it was removed. The
    // per-part container check inside the loop below still runs before
    // each individual replacement.)
    if (!wq_validate_container(container, bundleID, expectedDevice, expectedInode, error) ||
        !wq_validate_backup(safety, bundleID, NO, &parts, &safetyManifest, NULL, error) ||
        !wq_validate_backup_hashes(safety, parts, safetyManifest, error)) return NO;
    BOOL ok = YES;
    for (NSString *part in kAppBackupParts()) {
        NSString *saved = [safety stringByAppendingPathComponent:part];
        NSString *dst = [container stringByAppendingPathComponent:part];
        if (!wq_validate_container(container, bundleID, expectedDevice, expectedInode, error)) {
            ok = NO;
            break;
        }
        if ([parts containsObject:part]) {
            if (!wq_replace_part(saved, dst, error)) ok = NO;
        } else {
            unsigned long long ignored = 0;
            if (!wq_purge_and_verify(dst, &ignored, error)) {
                ok = NO;
            }
        }
        if (!ok) break;
    }
    if (ok && !wq_validate_container(container, bundleID, expectedDevice, expectedInode, error)) ok = NO;
    return ok;
}

// Called on the serial I/O queue at launch. An active journal means termination
// may have left only some restored parts in place, so reapply the safety state.
NSString *wq_recover_interrupted_restore(void)
{
    NSString *path = wq_restore_journal_path();
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!journal) return nil;
    NSString *state = [journal[@"State"] isKindOfClass:NSString.class] ? journal[@"State"] : nil;
    if ([state isEqualToString:@"Committed"]) {
        NSString *removeError = nil;
        if (!wq_remove_restore_journal(&removeError)) {
            wq_log(@"restore recovery: committed journal cleanup failed: %@", removeError);
        }
        return nil;
    }
    if (![state isEqualToString:@"Active"]) {
        wq_log(@"restore recovery: unknown journal state at %@", path);
        return @"发现一次中断的恢复，其恢复状态未知。记录已保留，可手动恢复。";
    }
    NSString *bundleID = journal[@"BundleID"], *container = journal[@"Container"], *safety = journal[@"Safety"];
    NSString *backup = journal[@"Backup"];
    id deviceValue = journal[@"ContainerDevice"];
    id inodeValue = journal[@"ContainerInode"];
    NSString *journalError = nil;
    BOOL stringFields = [bundleID isKindOfClass:NSString.class] && [container isKindOfClass:NSString.class] &&
        [safety isKindOfClass:NSString.class] && [backup isKindOfClass:NSString.class];
    BOOL identityFields = WQAppsSupportIsInteger(deviceValue) && WQAppsSupportIsInteger(inodeValue) &&
        [deviceValue compare:@1] != NSOrderedAscending && [inodeValue compare:@1] != NSOrderedAscending;
    dev_t device = identityFields ? [deviceValue unsignedLongLongValue] : 0;
    ino_t inode = identityFields ? [inodeValue unsignedLongLongValue] : 0;
    BOOL journalTyped = stringFields && WQAppsSupportIsInteger(journal[@"Format"]) && [journal[@"Format"] unsignedIntegerValue] == 2 &&
        identityFields && bundleID.length && container.length && safety.length && backup.length && device && inode &&
        wq_backup_root_child(backup, bundleID) && wq_backup_root_child(safety, bundleID) &&
        wq_validate_container(container, bundleID, device, inode, &journalError);
    if (!journalTyped) {
        wq_log(@"restore recovery: invalid journal or incomplete safety backup at %@", path);
        return [NSString stringWithFormat:@"发现一次中断的恢复，但其恢复记录无效。记录已保留，可手动恢复%@。",
                journalError.length ? [NSString stringWithFormat:@" (%@)", journalError] : @""];
    }
    NSString *error = nil;
    if (!wq_rollback_safety(container, bundleID, safety, device, inode, &error)) {
        wq_log(@"restore recovery for %@: FAILED (%@)", bundleID, error);
        return [NSString stringWithFormat:@"%@ 的自动恢复失败：%@。安全备份为 %@；请查看日志。",
                bundleID, error ?: @"未知错误", safety.lastPathComponent];
    }
    NSString *commitError = nil;
    NSString *removeError = nil;
    if (!wq_mark_restore_journal_committed(&commitError)) {
        wq_log(@"restore recovery for %@: recovered, journal commit failed (%@)", bundleID, commitError);
        return [NSString stringWithFormat:@"%@ 的中断恢复已恢复，但其记录无法提交（%@）。下次启动时将再次检查。",
                bundleID, commitError ?: @"未知错误"];
    }
    if (!wq_remove_restore_journal(&removeError)) {
        wq_log(@"restore recovery for %@: recovered, cleanup pending (%@)", bundleID, removeError);
        return [NSString stringWithFormat:@"%@ 的中断恢复已恢复。其已提交的记录将在下次启动时清理（%@）。",
                bundleID, removeError ?: @"清理失败"];
    }
    wq_log(@"restore recovery for %@: OK", bundleID);
    return [NSString stringWithFormat:@"%@ 的中断恢复已从其安全备份中恢复。", bundleID];
}

- (void)restore:(WQAppItem *)app from:(NSString *)backup title:(NSString **)title message:(NSString **)message
{
    // 1. Validate all typed manifest fields and all required parts before any
    // safety backup, journal, purge, or replacement is allowed.
    NSArray<NSString *> *parts = nil;
    NSDictionary *manifest = nil;
    BOOL verified = NO;
    NSString *error = nil;
    if (!wq_validate_backup(backup, app.bundleID, YES, &parts, &manifest, &verified, &error)) {
        *title = @"未恢复";
        *message = [NSString stringWithFormat:@"此备份恢复不安全（%@）。未更改任何内容。", error ?: @"清单无效"];
        return;
    }
    if (!verified && !parts.count) {
        *title = @"未恢复";
        *message = @"旧备份为空。未更改任何内容。";
        return;
    }
    if (!wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) {
        *title = @"未恢复";
        *message = [NSString stringWithFormat:@"所选应用容器已不再安全（%@）。未更改任何内容。", error];
        return;
    }
    // 2. Keep the current data and a durable recovery journal before touching
    // anything, so both ordinary failures and process termination are covered.
    NSString *safety = wq_make_app_backup(app.bundleID, app.container, app.containerDevice,
                                           app.containerInode, kBackupReasonBeforeRestore, &error);
    if (!safety) {
        *title = @"未恢复";
        *message = [NSString stringWithFormat:@"当前数据无法先备份（%@）。未更改任何内容。",
                    error ?: @"见日志"];
        return;
    }
    if (!wq_begin_restore_journal(app, backup, safety, &error)) {
        *title = @"未恢复";
        *message = [NSString stringWithFormat:@"%@。未更改任何内容；安全备份保留在 %@，可手动恢复。",
                    error ?: @"无法写入恢复记录", safety.lastPathComponent];
        return;
    }
    // 3. Re-read and validate the selected backup immediately before the first
    // mutation. A changed or incomplete source fails closed and retains the
    // journal/safety material.
    error = nil;
    NSArray<NSString *> *preRestoreParts = nil;
    NSDictionary *preRestoreManifest = nil;
    if (!wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error) ||
        !wq_validate_backup(backup, app.bundleID, YES, &preRestoreParts, &preRestoreManifest, NULL, &error) ||
        ![preRestoreParts isEqualToArray:parts] ||
        !wq_validate_backup_hashes(backup, preRestoreParts, preRestoreManifest, &error)) {
        error = error ?: @"所选备份在恢复前已更改";
    }
    BOOL ok = error == nil;
    NSDictionary *restorePlan = WQRestorePlan([parts containsObject:@"Documents"],
                                               [parts containsObject:@"Library"]);
    for (NSString *part in kAppBackupParts()) {
        if (!ok) break;
        NSString *src = [backup stringByAppendingPathComponent:part];
        NSString *dst = [app.container stringByAppendingPathComponent:part];
        if (!wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) {
            ok = NO;
            break;
        }
        if ([restorePlan[part] boolValue]) {
            if (!wq_replace_part(src, dst, &error)) { ok = NO; break; }
        } else {
            unsigned long long ignored = 0;
            if (!wq_purge_and_verify(dst, &ignored, &error)) {
                ok = NO;
                break;
            }
        }
    }
    // The backup was fully validated (manifest + content hashes) immediately
    // before the first mutation, and restore never writes to it, so there is
    // one validation, not a pre- and a post-restore copy of it. A post-hoc
    // manifest re-read could not detect content changes anyway — it performs
    // no hashing — and each part was shape-verified against the backup at
    // copy time; a part deleted mid-restore fails its copy and rolls back,
    // and a part added mid-restore is outside the validated plan and is
    // ignored. Only the container still needs a final check.
    if (ok && !wq_validate_container(app.container, app.bundleID, app.containerDevice, app.containerInode, &error)) {
        ok = NO;
        error = error ?: @"应用容器在恢复期间已更改";
    }
    if (ok) {
        NSString *commitError = nil;
        NSString *removeError = nil;
        if (wq_mark_restore_journal_committed(&commitError)) {
            BOOL removed = wq_remove_restore_journal(&removeError);
            if (!removed) wq_log(@"restore %@: journal cleanup pending (%@)", app.bundleID, removeError);
            wq_log(@"restore %@ from %@: OK", app.bundleID, backup.lastPathComponent);
            *title = @"已恢复";
            NSString *cleanup = removed ? @"" : @" 恢复记录已提交，将在下次启动时清理。";
            *message = [NSString stringWithFormat:@"请打开 %@ 以使用恢复的 Documents 和 Library。之前的数据保留为备份 %@；tmp 未更改。在此操作期间请保持应用关闭。%@",
                        app.name, safety.lastPathComponent, cleanup];
            return;
        }
        // The journal is still Active. Rolling back is the only safe outcome
        // if it cannot be marked committed, because a completed restore must
        // not be rolled back by the next launch.
        error = [NSString stringWithFormat:@"恢复已完成，但其恢复记录无法提交（%@）", commitError];
    }
    wq_log(@"restore %@ from %@: FAILED (%@), rolling back", app.bundleID, backup.lastPathComponent, error);
    NSString *rollbackError = nil;
    BOOL rolledBack = wq_rollback_safety(app.container, app.bundleID, safety,
                                          app.containerDevice, app.containerInode, &rollbackError);
    // Keep the journal when the rollback failed, so the next launch tries the
    // recovery again instead of leaving the app half restored.
    NSString *cleanupError = nil;
    BOOL cleared = NO;
    if (rolledBack) cleared = wq_finish_restore_journal(&cleanupError);
    if (!rolledBack) cleanupError = @"kept for recovery at the next launch";
    wq_log(@"restore %@: rollback %@, journal %@", app.bundleID,
           rolledBack ? @"OK" : @"FAILED", cleared ? @"cleared" : cleanupError);
    *title = @"恢复失败";
    *message = rolledBack
        ? [NSString stringWithFormat:@"%@。之前的数据已还原。%@", error ?: @"有些文件无法写入",
           cleared ? @"" : @" 由于无法删除记录，恢复将在下次启动时再次运行。"]
        : [NSString stringWithFormat:@"%@，且还原之前数据也失败了（%@）。数据在备份 %@ 中；请查看日志。%@",
           error ?: @"有些文件无法写入", rollbackError ?: @"见日志", safety.lastPathComponent,
           cleared ? @"" : @" 恢复将在下次启动时再次运行。"];
}

@end
