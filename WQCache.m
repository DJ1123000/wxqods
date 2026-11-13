//
//  WQCache.m
//  WQ Files cache cleaner
//  GPL-3.0-or-later.
//

#import "WQCache.h"
#import "WQDir.h"
#import "WQUI.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQCacheSafety.h"
#import "WQOperation.h"

#import <errno.h>
#import <sys/stat.h>

#pragma mark - Cache cleaner

static NSString *const kCrashLogsPath =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter";

@interface WQCacheTargetRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic) BOOL existed;
@property (nonatomic) BOOL identityKnown;
@property (nonatomic) dev_t device;
@property (nonatomic) ino_t inode;
@property (nonatomic) mode_t mode;
@end
@implementation WQCacheTargetRecord
@end

@interface WQCacheItem : NSObject
@property (nonatomic, copy) NSString *name;        // app name or "Crash Logs"
@property (nonatomic, copy) NSString *bundleID;    // for the icon; nil for logs
@property (nonatomic, copy) NSArray<NSString *> *targets;  // dirs to purge
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
@property (nonatomic) BOOL cacheKnown;
@property (nonatomic) BOOL tempKnown;
@property (nonatomic) BOOL limited;
@property (nonatomic) BOOL crashLogs;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic) BOOL containerIdentityKnown;
@property (nonatomic) dev_t containerDevice;
@property (nonatomic) ino_t containerInode;
@property (nonatomic) mode_t containerMode;
@property (nonatomic, copy) NSArray<WQCacheTargetRecord *> *targetRecords;
@property (nonatomic) BOOL selected;
@property (nonatomic, readonly) unsigned long long bytes;
@end
@implementation WQCacheItem
- (unsigned long long)bytes { return self.cacheBytes + self.tempBytes; }
@end

static void WQCacheSelectionCategories(NSArray<WQCacheItem *> *items,
                                       BOOL *hasApps,
                                       BOOL *hasCrashLogs,
                                       NSUInteger *appCount)
{
    BOOL apps = NO, crashLogs = NO;
    NSUInteger count = 0;
    for (WQCacheItem *item in items) {
        if (item.crashLogs) {
            crashLogs = YES;
        } else {
            apps = YES;
            count++;
        }
    }
    if (hasApps) *hasApps = apps;
    if (hasCrashLogs) *hasCrashLogs = crashLogs;
    if (appCount) *appCount = count;
}

static NSString *WQCacheConfirmationScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    NSUInteger appCount = 0;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, &appCount);
    if (hasApps && hasCrashLogs) {
        return [NSString stringWithFormat:@"删除 %lu 个应用的 Library/Caches 和 tmp，以及崩溃日志",
                (unsigned long)appCount];
    }
    if (hasApps) {
        return [NSString stringWithFormat:@"删除 %lu 个应用的 Library/Caches 和 tmp",
                (unsigned long)appCount];
    }
    if (hasCrashLogs) return @"删除崩溃日志";
    return @"删除选定的缓存目标";
}

static NSString *WQCacheFooterScope(NSArray<WQCacheItem *> *items)
{
    BOOL hasApps = NO, hasCrashLogs = NO;
    WQCacheSelectionCategories(items, &hasApps, &hasCrashLogs, NULL);
    if (hasApps && hasCrashLogs) {
        return @"清除每个选定应用的 Library/Caches 和 tmp，并删除选定的崩溃日志。应用在使用过程中会重建缓存；"
                "有些应用将离线内容（音乐、地图、下载）存放在其中，"
                "之后会重新下载。不保留备份。";
    }
    if (hasApps) {
        return @"清除每个选定应用的 Library/Caches 和 tmp。应用在使用过程中会重建缓存；"
                "有些应用将离线内容（音乐、地图、下载）存放在其中，之后会重新下载。不保留备份"
                "。";
    }
    if (hasCrashLogs) return @"删除选定的崩溃日志。此操作无法撤销。不保留备份。";
    return @"选择应用缓存或崩溃日志以查看删除范围。不保留备份。";
}

typedef NS_ENUM(NSInteger, WQCacheMeasurementState) {
    WQCacheMeasurementMissing,
    WQCacheMeasurementKnown,
    WQCacheMeasurementLimited,
    WQCacheMeasurementCancelled,
};

static WQCacheMeasurementState WQCacheMeasureDirectory(NSString *path,
                                                        WQScanCancellation *cancellation,
                                                        unsigned long long *bytes)
{
    unsigned long long total = 0;
    WQMeasureResult result = wq_measure_tree(path, cancellation, &total);
    switch (result) {
        case WQMeasureResultMissing:
            return WQCacheMeasurementMissing;
        case WQMeasureResultKnown:
            if (bytes) *bytes = total;
            return WQCacheMeasurementKnown;
        case WQMeasureResultCancelled:
            return WQCacheMeasurementCancelled;
        case WQMeasureResultLimited:
            wq_log(@"cache scan: limited tree measurement for %@", path);
            return WQCacheMeasurementLimited;
    }
    return WQCacheMeasurementLimited;
}

// Items 1-2: Library/Caches and tmp from one traversal of the container,
// reusing the size cache shared with the Apps screen when it is fresh. On a
// miss (or a stale entry) the container is measured once with subtotals and
// stored for both screens. A bucket is Known when its own subtree measured
// cleanly; a failure under Documents limits only the Documents bucket, never
// Caches/tmp. A missing Caches or tmp dir is 0 bytes, known — as before.
// The per-target safety gates still decide whether a bucket may be reported
// at all: an unsafe target is Limited with 0 bytes even when the traversal
// saw it. Returns NO only when the measurement was cancelled.
static BOOL WQCacheMeasureContainer(NSString *container, BOOL granted, BOOL safeContainer,
                                    BOOL safeCaches, BOOL safeTmp,
                                    WQScanCancellation *cancellation,
                                    unsigned long long *cacheBytes, unsigned long long *tempBytes,
                                    WQCacheMeasurementState *cacheState, WQCacheMeasurementState *tempState)
{
    if (cacheBytes) *cacheBytes = 0;
    if (tempBytes) *tempBytes = 0;
    if (cacheState) *cacheState = WQCacheMeasurementLimited;
    if (tempState) *tempState = WQCacheMeasurementLimited;
    if (!granted || !safeContainer) return YES;   // limited, as before
    WQTreeSubtotals sub = {0};
    BOOL stale = NO;
    if (wq_container_size_lookup(container, &sub, NULL, &stale) && !stale) {
        // Fresh cached subtotals; no traversal.
    } else {
        WQMeasureResult result = wq_measure_tree_subtotals(container, cancellation, &sub);
        if (result == WQMeasureResultCancelled) return NO;
        if (result == WQMeasureResultMissing) {
            if (cacheState) *cacheState = WQCacheMeasurementMissing;
            if (tempState) *tempState = WQCacheMeasurementMissing;
            return YES;
        }
        BOOL anyLimited = sub.documentsLimited || sub.cachesLimited || sub.tmpLimited || sub.otherLimited;
        wq_container_size_store(container, &sub, anyLimited);
    }
    if (safeCaches) {
        if (cacheBytes) *cacheBytes = sub.caches;
        if (cacheState) *cacheState = sub.cachesLimited ? WQCacheMeasurementLimited : WQCacheMeasurementKnown;
    }
    if (safeTmp) {
        if (tempBytes) *tempBytes = sub.tmp;
        if (tempState) *tempState = sub.tmpLimited ? WQCacheMeasurementLimited : WQCacheMeasurementKnown;
    }
    return YES;
}

typedef NS_ENUM(NSInteger, WQCachePathState) {
    WQCachePathMissing,
    WQCachePathExisting,
    WQCachePathInaccessible,
};

static WQCachePathState WQCacheInspectPath(NSString *path, struct stat *st)
{
    if (wq_stat(path, st)) return WQCachePathExisting;
    struct stat direct = {0};
    if (lstat(path.fileSystemRepresentation, &direct) == 0) {
        if (st) *st = direct;
        return WQCachePathExisting;
    }
    if (errno == ENOENT || errno == ENOTDIR) return WQCachePathMissing;
    return WQCachePathInaccessible;
}

static WQCacheTargetRecord *WQCacheTargetRecordForPath(NSString *path, NSString *relativePath)
{
    WQCacheTargetRecord *record = [WQCacheTargetRecord new];
    record.path = path;
    record.relativePath = relativePath;
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(path, &st);
    if (state == WQCachePathExisting) {
        record.existed = YES;
        record.identityKnown = YES;
        record.device = st.st_dev;
        record.inode = st.st_ino;
        record.mode = st.st_mode & S_IFMT;
    }
    return record;
}

static void WQCacheCaptureContainerIdentity(WQCacheItem *item)
{
    struct stat st = {0};
    if (item.containerPath.length && wq_stat(item.containerPath, &st) && S_ISDIR(st.st_mode)) {
        item.containerIdentityKnown = YES;
        item.containerDevice = st.st_dev;
        item.containerInode = st.st_ino;
        item.containerMode = st.st_mode & S_IFMT;
    }
}

static BOOL WQCacheRecordIdentityMatches(WQCacheTargetRecord *record, NSString **reason)
{
    struct stat st = {0};
    WQCachePathState state = WQCacheInspectPath(record.path, &st);
    if (!record.existed) {
        if (state == WQCachePathMissing) return YES;
        if (reason) *reason = [NSString stringWithFormat:@"%@ 在扫描后出现", record.path];
        return NO;
    }
    if (state != WQCachePathExisting || !record.identityKnown ||
        st.st_dev != record.device || st.st_ino != record.inode ||
        (st.st_mode & S_IFMT) != record.mode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ 在扫描后已更改", record.path];
        return NO;
    }
    return YES;
}

static BOOL WQCacheCrashPathIsSafe(NSString *path)
{
    NSString *expected = [kCrashLogsPath stringByStandardizingPath];
    return [[path stringByStandardizingPath] isEqualToString:expected] &&
           WQCacheSafetyHasNoSymlinkAncestry(path, YES) &&
           [WQCacheSafetyCanonicalPath(path) isEqualToString:expected];
}

static BOOL WQCacheValidateItem(WQCacheItem *item, NSString **reason)
{
    if (item.limited) {
        if (reason) *reason = @"扫描时访问受限";
        return NO;
    }
    if (item.crashLogs) {
        if (item.targetRecords.count != 1 || !WQCacheCrashPathIsSafe(item.targets.firstObject)) {
            if (reason) *reason = @"崩溃日志目标不是预期的规范目录";
            return NO;
        }
        return WQCacheRecordIdentityMatches(item.targetRecords.firstObject, reason);
    }
    if (item.targetRecords.count != 2 || item.targets.count != 2 ||
        ![item.targets[0] isEqualToString:item.targetRecords[0].path] ||
        ![item.targets[1] isEqualToString:item.targetRecords[1].path]) {
        if (reason) *reason = @"扫描的缓存目标不完整";
        return NO;
    }
    if (!item.containerIdentityKnown || !WQCacheSafetyHasNoSymlinkAncestry(item.containerPath, NO)) {
        if (reason) *reason = @"应用容器身份或祖先路径不可用";
        return NO;
    }
    struct stat container = {0};
    if (WQCacheInspectPath(item.containerPath, &container) != WQCachePathExisting ||
        !S_ISDIR(container.st_mode) || container.st_dev != item.containerDevice ||
        container.st_ino != item.containerInode || (container.st_mode & S_IFMT) != item.containerMode) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ 在扫描后已更改", item.name];
        return NO;
    }
    NSString *label = wq_container_label(item.containerPath);
    if (!item.bundleID.length || ![label isEqualToString:item.bundleID]) {
        if (reason) *reason = [NSString stringWithFormat:@"%@ 不再具有扫描时的容器身份", item.name];
        return NO;
    }
    for (WQCacheTargetRecord *record in item.targetRecords) {
        if (!WQCacheSafetyTargetMatchesContainer(record.path, item.containerPath, record.relativePath)) {
            if (reason) *reason = [NSString stringWithFormat:@"%@ 的路径祖先不安全", record.path];
            return NO;
        }
        if (!WQCacheRecordIdentityMatches(record, reason)) return NO;
    }
    return YES;
}

// Row: selection circle, icon, name with "cache · temp" below, size in a
// fixed right-hand column so long names never push it out.
@interface WQCleanerCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView, *iconView;
@property (nonatomic, strong) UILabel *nameLabel, *detailLabel, *sizeLabel;
@end

@implementation WQCleanerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _checkView = [UIImageView new];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _sizeLabel = [UILabel new];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _sizeLabel.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[_checkView, _iconView, _nameLabel, _detailLabel, _sizeLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_sizeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_checkView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkView.widthAnchor constraintEqualToConstant:24],
            [_checkView.heightAnchor constraintEqualToConstant:24],
            [_iconView.leadingAnchor constraintEqualToAnchor:_checkView.trailingAnchor constant:12],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:36],
            [_iconView.heightAnchor constraintEqualToConstant:36],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sizeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11],
        ]];
    }
    return self;
}

@end

// Summary card: reclaimable total, a bar for the selected share, status.
@interface WQSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *captionLabel, *totalLabel, *statusLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation WQSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _totalLabel = [UILabel new];
        _totalLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle]
                            scaledFontForFont:[UIFont systemFontOfSize:34 weight:UIFontWeightBold]];
        _totalLabel.adjustsFontForContentSizeCategory = YES;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = UIColor.systemBlueColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 0;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        UIStackView *captionRow = [[UIStackView alloc] initWithArrangedSubviews:@[_captionLabel, _spinner]];
        captionRow.spacing = 8;
        captionRow.alignment = UIStackViewAlignmentCenter;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[captionRow, _totalLabel, _bar, _statusLabel]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:10 afterView:_totalLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

@end

// Long operations here (scan, clean) keep alive through the shared
// WQOperation keep-alive instead of a local background task. On expiration
// the operation is NOT cancelled: the worker checkpoints its progress and
// the scan/clean resumes from that checkpoint instead of restarting.
// See WQOperation.h.

// Checkpoint encode/decode for a cache item. The scan-time identities
// (container device/inode/mode and each target record's identity) are
// stored, not re-derived, so WQCacheValidateItem still detects a target
// that changed between the scan and the clean.
static NSDictionary *WQCacheTargetRecordEncode(WQCacheTargetRecord *record)
{
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"path"] = record.path ?: @"";
    if (record.relativePath.length) dict[@"relativePath"] = record.relativePath;
    dict[@"existed"] = @(record.existed);
    dict[@"identityKnown"] = @(record.identityKnown);
    dict[@"device"] = @(record.device);
    dict[@"inode"] = @(record.inode);
    dict[@"mode"] = @(record.mode);
    return dict;
}

static WQCacheTargetRecord *WQCacheTargetRecordDecode(NSDictionary *dict)
{
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    NSString *path = [dict[@"path"] isKindOfClass:NSString.class] ? dict[@"path"] : nil;
    if (!path.length) return nil;
    WQCacheTargetRecord *record = [WQCacheTargetRecord new];
    record.path = path;
    if ([dict[@"relativePath"] isKindOfClass:NSString.class]) record.relativePath = dict[@"relativePath"];
    record.existed = [dict[@"existed"] boolValue];
    record.identityKnown = [dict[@"identityKnown"] boolValue];
    record.device = [dict[@"device"] unsignedLongLongValue];
    record.inode = [dict[@"inode"] unsignedLongLongValue];
    record.mode = [dict[@"mode"] unsignedIntValue];
    return record;
}

static NSDictionary *WQCacheItemEncode(WQCacheItem *item)
{
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"name"] = item.name ?: @"";
    if (item.bundleID.length) dict[@"bundleID"] = item.bundleID;
    dict[@"cacheBytes"] = @(item.cacheBytes);
    dict[@"tempBytes"] = @(item.tempBytes);
    dict[@"cacheKnown"] = @(item.cacheKnown);
    dict[@"tempKnown"] = @(item.tempKnown);
    dict[@"limited"] = @(item.limited);
    dict[@"crashLogs"] = @(item.crashLogs);
    if (item.containerPath.length) dict[@"containerPath"] = item.containerPath;
    dict[@"containerIdentityKnown"] = @(item.containerIdentityKnown);
    dict[@"containerDevice"] = @(item.containerDevice);
    dict[@"containerInode"] = @(item.containerInode);
    dict[@"containerMode"] = @(item.containerMode);
    dict[@"selected"] = @(item.selected);
    NSMutableArray *records = [NSMutableArray new];
    for (WQCacheTargetRecord *record in item.targetRecords) {
        [records addObject:WQCacheTargetRecordEncode(record)];
    }
    dict[@"targetRecords"] = records;
    return dict;
}

static WQCacheItem *WQCacheItemDecode(NSDictionary *dict)
{
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    NSString *name = [dict[@"name"] isKindOfClass:NSString.class] ? dict[@"name"] : nil;
    if (!name.length) return nil;
    WQCacheItem *item = [WQCacheItem new];
    item.name = name;
    if ([dict[@"bundleID"] isKindOfClass:NSString.class]) item.bundleID = dict[@"bundleID"];
    item.cacheBytes = [dict[@"cacheBytes"] unsignedLongLongValue];
    item.tempBytes = [dict[@"tempBytes"] unsignedLongLongValue];
    item.cacheKnown = [dict[@"cacheKnown"] boolValue];
    item.tempKnown = [dict[@"tempKnown"] boolValue];
    item.limited = [dict[@"limited"] boolValue];
    item.crashLogs = [dict[@"crashLogs"] boolValue];
    if ([dict[@"containerPath"] isKindOfClass:NSString.class]) item.containerPath = dict[@"containerPath"];
    item.containerIdentityKnown = [dict[@"containerIdentityKnown"] boolValue];
    item.containerDevice = [dict[@"containerDevice"] unsignedLongLongValue];
    item.containerInode = [dict[@"containerInode"] unsignedLongLongValue];
    item.containerMode = [dict[@"containerMode"] unsignedIntValue];
    item.selected = [dict[@"selected"] boolValue];
    if (item.crashLogs) {
        item.targets = @[kCrashLogsPath];
    } else if (item.containerPath.length) {
        NSString *caches = [item.containerPath stringByAppendingPathComponent:@"Library/Caches"];
        NSString *tmp = [item.containerPath stringByAppendingPathComponent:@"tmp"];
        item.targets = @[caches, tmp];
    }
    NSMutableArray *records = [NSMutableArray new];
    for (NSDictionary *recordDict in [dict[@"targetRecords"] isKindOfClass:NSArray.class] ? dict[@"targetRecords"] : @[]) {
        WQCacheTargetRecord *record = WQCacheTargetRecordDecode(recordDict);
        if (record) [records addObject:record];
    }
    item.targetRecords = records;
    return item;
}

// Whether a checkpoint-restored item's container is still the same
// directory it was measured in. A changed or vanished container is
// dropped from the restored list (and re-measured) instead of shown stale.
static BOOL WQCacheItemContainerStillAlive(WQCacheItem *item)
{
    if (item.crashLogs) return YES;
    if (!item.containerIdentityKnown || !item.containerPath.length) return NO;
    struct stat st = {0};
    if (!wq_stat(item.containerPath, &st) || !S_ISDIR(st.st_mode)) return NO;
    return st.st_dev == item.containerDevice && st.st_ino == item.containerInode &&
           (st.st_mode & S_IFMT) == item.containerMode;
}

// Saves a clean checkpoint: the selected items plus the index of the next
// unprocessed item, so a paused clean resumes instead of restarting.
static void WQCacheSaveCleanCheckpoint(NSArray<WQCacheItem *> *selected, NSUInteger nextIndex,
                                       unsigned long long freed, BOOL allOk)
{
    NSMutableArray *encoded = [NSMutableArray new];
    for (WQCacheItem *item in selected) [encoded addObject:WQCacheItemEncode(item)];
    wq_operation_checkpoint_save(@"cache-clean", @{
        @"version": @1,
        @"items": encoded,
        @"nextIndex": @(nextIndex),
        @"freed": @(freed),
        @"allOk": @(allOk),
    });
}

@interface WQCacheCleanerViewController ()
- (void)scan;
- (void)clean;
- (void)resumeClean;
- (NSUInteger)runCleanLoop:(NSArray<WQCacheItem *> *)selected
                startIndex:(NSUInteger)startIndex
                     freed:(unsigned long long *)freedPtr
                     allOk:(BOOL *)allOkPtr
              cancellation:(WQScanCancellation *)cancellation
                    paused:(BOOL *)pausedPtr
         validationFailure:(NSString **)validationFailurePtr;
- (void)finishClean:(NSArray<WQCacheItem *> *)selected
              freed:(unsigned long long)freed
              allOk:(BOOL)allOk
             paused:(BOOL)paused
           cancelled:(BOOL)cancelled
  validationFailure:(NSString *)validationFailure;
@end

@implementation WQCacheCleanerViewController {
    NSArray<WQCacheItem *> *_items;
    NSArray<WQCacheItem *> *_visibleItems;
    NSString *_query;
    NSString *_status;   // scan / clean progress, nil when idle
    NSString *_result;   // last clean result
    BOOL _scanning, _cleaning, _scanLimited, _cleanRequiresRescan;
    WQScanCancellation *_scanCancellation;
    WQScanCancellation *_cleanCancellation;
    NSUInteger _scanGeneration;
    NSTimeInterval _lastScanFinished;
    NSUInteger _interruptedRestarts; // auto-restarts after an interrupted scan, capped (see publish)
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"缓存清理";
    self.tableView.tableHeaderView = wq_device_header(self.view.bounds.size.width);
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    // A clean that paused (background time expired) resumes instead of
    // starting a fresh scan; otherwise start a scan as before.
    if (wq_operation_checkpoint_load(@"cache-clean")) [self resumeClean];
    else [self scan];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // A user-driven (re)appearance starts a fresh auto-restart budget for
    // interrupted scans (see the publish block).
    _interruptedRestarts = 0;
    // A clean that paused while this page was away resumes where it left
    // off instead of restarting the scan from scratch.
    if (!_scanning && !_cleaning && wq_operation_checkpoint_load(@"cache-clean")) {
        [self resumeClean];
        return;
    }
    if (_scanning && _scanCancellation.isCancelled) {
        [self scan];
        return;
    }
    if (!_scanning && !_cleaning && _lastScanFinished > 0 &&
        NSDate.date.timeIntervalSinceReferenceDate - _lastScanFinished > 60.0) {
        [self scan];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // Leaving the page no longer cancels a scan or a clean: the work is
    // owned by the operation, not by this screen. It keeps running in the
    // background (keep-alive) and, if the app is terminated while
    // suspended, resumes from its checkpoint when the user returns. Only
    // an explicit user stop cancels.
    [self.refreshControl endRefreshing];
}

- (NSArray<WQCacheItem *> *)visibleItems
{
    return _visibleItems ?: @[];
}

- (void)rebuildVisibleItems
{
    if (!_query.length) {
        _visibleItems = _items;
        return;
    }
    _visibleItems = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQCacheItem *it, NSDictionary *__unused b) {
        return [it.name localizedCaseInsensitiveContainsString:self->_query] ||
               (it.bundleID && [it.bundleID localizedCaseInsensitiveContainsString:self->_query]);
    }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self rebuildVisibleItems];
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)setStatus:(NSString *)status
{
    _status = status;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateButtons
{
    if (_scanning) {
        self.navigationItem.rightBarButtonItems = nil;
        return;
    }
    if (_cleaning) {
        UIBarButtonItem *stop = [[UIBarButtonItem alloc] initWithTitle:@"停止" style:UIBarButtonItemStylePlain
                                                                 target:self action:@selector(stopClean)];
        self.navigationItem.rightBarButtonItems = @[stop];
        return;
    }
    NSUInteger n = 0;
    for (WQCacheItem *it in _items) if (it.selected) n++;
    UIBarButtonItem *clean = [[UIBarButtonItem alloc] initWithTitle:@"清理" style:wq_primary_button_style()
                                                             target:self action:@selector(confirmClean)];
    clean.enabled = n > 0 && !_cleanRequiresRescan;
    NSArray *visible = self.visibleItems;
    BOOL allVisible = visible.count > 0;
    for (WQCacheItem *it in visible) if (it.limited || !it.selected) { allVisible = NO; break; }
    __weak typeof(self) weakSelf = self;
    UIAction *__unused all = [UIAction actionWithTitle:@"全选" image:[UIImage systemImageNamed:@"checkmark.circle"]
                                   identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return YES; }]; }];
    UIAction *none = [UIAction actionWithTitle:@"全不选" image:[UIImage systemImageNamed:@"circle"]
                                    identifier:nil handler:^(UIAction *__unused a) { [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return NO; }]; }];
    UIAction *large = [UIAction actionWithTitle:@"选择大缓存（50 MB 以上）" image:[UIImage systemImageNamed:@"arrow.up.circle"]
                                     identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf selectWhere:^BOOL(WQCacheItem *__unused it) { return it.bytes >= 50ull * 1000 * 1000; }];
    }];
    all.state = allVisible ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIBarButtonItem *select = [[UIBarButtonItem alloc] initWithTitle:@"选择"
                                                                menu:[UIMenu menuWithChildren:@[all, none, large]]];
    select.enabled = visible.count > 0;
    self.navigationItem.rightBarButtonItems = @[clean, select];
}

// Pull to refresh: rescan the containers instead of reusing the shared scan,
// and look for the app name database again if it wasn't found before.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_container_size_invalidate_all();
    wq_display_names_reset_miss();
    _interruptedRestarts = 0;
    // A user refresh is a fresh start, not a resume: drop any checkpoint.
    wq_operation_checkpoint_clear(@"cache-scan");
    [self scan];
}

- (void)scan
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanning = YES;
    _scanLimited = NO;
    _cleanRequiresRescan = NO;
    _result = nil;
    [self updateButtons];
    [self setStatus:@"正在查找应用…"];
    // Keep the scan alive if the user switches apps or locks the screen
    // (shared keep-alive, about 30 s of background time). On expiration
    // the scan is NOT cancelled: the worker below checkpoints its
    // progress, and a later run resumes from that checkpoint instead of
    // starting over. Only an explicit new scan (or a user refresh)
    // supersedes this one.
    wq_operation_keep_alive_begin(@"WQ cache scan");
    dispatch_async(wq_io_scan(), ^{
        NSMutableArray<WQCacheItem *> *items = [NSMutableArray new];
        NSMutableArray<NSString *> *emptyRoots = [NSMutableArray new];
        // __block: the checkpoint block below reads these as they change.
        __block BOOL scanLimited = NO;
        __block BOOL interrupted = NO;
        __block NSUInteger failedEnumerations = 0;
        __block NSUInteger limitedContainers = 0;
        __block NSUInteger limitedMeasurements = 0;
        __block NSUInteger missingIdentities = 0;
        __block BOOL crashMeasured = NO;
        __block unsigned long long crashBytes = 0;
        __block BOOL crashKnown = NO;
        // Resume from a checkpoint when one exists (the app was terminated
        // while suspended, or an earlier scan was interrupted): restored
        // items are kept, already-measured containers are skipped, and only
        // the rest is measured. A container whose identity changed since
        // the checkpoint is dropped and re-measured.
        NSMutableSet<NSString *> *measured = [NSMutableSet new];
        NSDictionary *checkpoint = wq_operation_checkpoint_load(@"cache-scan");
        if (checkpoint) {
            for (NSDictionary *itemDict in [checkpoint[@"items"] isKindOfClass:NSArray.class] ? checkpoint[@"items"] : @[]) {
                WQCacheItem *restored = WQCacheItemDecode(itemDict);
                if (!restored) continue;
                if (!WQCacheItemContainerStillAlive(restored)) {
                    wq_log(@"cache scan: dropping checkpoint item %@ (container changed)", restored.name);
                    continue;
                }
                [items addObject:restored];
                if (restored.containerPath.length) [measured addObject:restored.containerPath];
            }
            for (NSString *path in [checkpoint[@"measured"] isKindOfClass:NSArray.class] ? checkpoint[@"measured"] : @[]) {
                if ([path isKindOfClass:NSString.class]) [measured addObject:path];
            }
            scanLimited = [checkpoint[@"scanLimited"] boolValue];
            failedEnumerations = [checkpoint[@"failedEnumerations"] unsignedIntegerValue];
            limitedContainers = [checkpoint[@"limitedContainers"] unsignedIntegerValue];
            limitedMeasurements = [checkpoint[@"limitedMeasurements"] unsignedIntegerValue];
            missingIdentities = [checkpoint[@"missingIdentities"] unsignedIntegerValue];
            crashMeasured = [checkpoint[@"crashMeasured"] boolValue];
            crashBytes = [checkpoint[@"crashBytes"] unsignedLongLongValue];
            crashKnown = [checkpoint[@"crashKnown"] boolValue];
            if (items.count || measured.count) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    [self setStatus:@"继续查找应用…"];
                });
                wq_log(@"cache scan: resuming from checkpoint (%lu items, %lu containers measured)",
                       (unsigned long)items.count, (unsigned long)measured.count);
            }
        }
        // Saves the checkpoint from this worker thread (it owns the state,
        // so there is no race with the main thread). Called every 20
        // containers and when the background time expires.
        NSUInteger sinceCheckpoint = 0;
        void (^saveCheckpoint)(void) = ^{
            NSMutableArray *encoded = [NSMutableArray new];
            for (WQCacheItem *item in items) [encoded addObject:WQCacheItemEncode(item)];
            wq_operation_checkpoint_save(@"cache-scan", @{
                @"version": @1,
                @"items": encoded,
                @"measured": [measured allObjects],
                @"scanLimited": @(scanLimited),
                @"failedEnumerations": @(failedEnumerations),
                @"limitedContainers": @(limitedContainers),
                @"limitedMeasurements": @(limitedMeasurements),
                @"missingIdentities": @(missingIdentities),
                @"crashMeasured": @(crashMeasured),
                @"crashBytes": @(crashBytes),
                @"crashKnown": @(crashKnown),
            });
        };
        NSArray *roots = @[@"/private/var/mobile/Containers/Data/Application",
                           @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
        for (NSString *root in roots) {
            if (cancellation.isCancelled) { interrupted = YES; break; }
            NSString *kind = [root.lastPathComponent isEqualToString:@"Application"] ? @"应用" : @"扩展";
            void (^progress)(int64_t, int64_t, NSUInteger) = ^(int64_t done, int64_t total, NSUInteger __unused f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    [self setStatus:[NSString stringWithFormat:@"正在查找 %@… %lld%%", kind, (long long)(done * 100 / total)]];
                });
            };
            NSArray *containers = wq_enumerate(root, 0, cancellation, progress);
            if (!containers && !cancellation.isCancelled) {
                // One enumeration can fail transiently after the app was
                // suspended and resumed (a dropped container-manager /
                // LaunchServices IPC, or a stale sandbox grant). Re-establish
                // access and try once more before giving up on the root.
                wq_log(@"cache scan: %@ container enumeration failed; retrying once", kind);
                (void)wq_grant(root);
                containers = wq_enumerate(root, 0, cancellation, progress);
            }
            if (!containers) {
                if (cancellation.isCancelled) { interrupted = YES; break; }
                scanLimited = YES;
                failedEnumerations++;
                wq_log(@"cache scan: %@ container enumeration failed", kind);
                continue;
            }
            if (!cancellation.isCancelled && !wq_display_names_loaded()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                [self setStatus:@"正在读取应用名称…"];
            });
            wq_load_display_names();
        }
            if (!containers.count) [emptyRoots addObject:kind];
            NSUInteger idx = 0;
            for (NSString *c in containers) {
                if (cancellation.isCancelled) { interrupted = YES; break; }
                idx++;
                if (idx % 10 == 0 || idx == containers.count) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                        [self setStatus:[NSString stringWithFormat:@"正在测量 %@ %lu/%lu…", kind,
                                         (unsigned long)idx, (unsigned long)containers.count]];
                    });
                }
                // Resuming from a checkpoint: skip containers already measured.
                if ([measured containsObject:c]) continue;
                BOOL safeContainer = WQCacheSafetyHasNoSymlinkAncestry(c, NO);
                BOOL granted = safeContainer && wq_grant(c);  // one token for the whole container
                NSString *caches = [c stringByAppendingPathComponent:@"Library/Caches"];
                NSString *tmp = [c stringByAppendingPathComponent:@"tmp"];
                unsigned long long cacheBytes = 0, tempBytes = 0;
                BOOL safeCaches = safeContainer &&
                    WQCacheSafetyTargetMatchesContainer(caches, c, @"Library/Caches");
                BOOL safeTmp = safeContainer &&
                    WQCacheSafetyTargetMatchesContainer(tmp, c, @"tmp");
                WQCacheMeasurementState cacheState = WQCacheMeasurementLimited;
                WQCacheMeasurementState tempState = WQCacheMeasurementLimited;
                if (!WQCacheMeasureContainer(c, granted, safeContainer, safeCaches, safeTmp,
                                             cancellation, &cacheBytes, &tempBytes,
                                             &cacheState, &tempState)) { interrupted = YES; break; }
                // Measured: remember it so a later run skips it, and
                // checkpoint every 20 containers (or when the background
                // time expired) so an interruption resumes instead of
                // restarting from scratch. A cancelled (superseded) scan
                // must not overwrite the checkpoint a fresh scan cleared.
                [measured addObject:c];
                sinceCheckpoint++;
                if (!cancellation.isCancelled &&
                    (sinceCheckpoint >= 20 || wq_operation_background_expiring())) {
                    sinceCheckpoint = 0;
                    saveCheckpoint();
                    wq_operation_clear_background_expiring();
                }
                if (!granted || !safeContainer) {
                    scanLimited = YES;
                    limitedContainers++;
                    wq_log(@"cache scan: %@ (%@) %@", c.lastPathComponent, wq_bundle_id_for_container(c) ?: @"unknown app",
                           safeContainer ? @"refused access" : @"failed the path safety check");
                }
                if (cacheState == WQCacheMeasurementLimited || tempState == WQCacheMeasurementLimited) {
                    scanLimited = YES;
                    limitedMeasurements++;
                }
                BOOL cacheKnown = cacheState != WQCacheMeasurementLimited;
                BOOL tempKnown = tempState != WQCacheMeasurementLimited;
                if (cacheKnown && tempKnown && cacheBytes + tempBytes < 64 * 1024) continue;
                WQCacheItem *item = [WQCacheItem new];
                NSString *bid = granted ? wq_container_label(c) : nil;
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.name = wq_display_name(bid) ?: bid ?: c.lastPathComponent;
                item.targets = @[caches, tmp];
                item.cacheBytes = cacheBytes;
                item.tempBytes = tempBytes;
                item.cacheKnown = cacheKnown;
                item.tempKnown = tempKnown;
                item.limited = !cacheKnown || !tempKnown;
                item.containerPath = c;
                item.targetRecords = @[
                    WQCacheTargetRecordForPath(caches, @"Library/Caches"),
                    WQCacheTargetRecordForPath(tmp, @"tmp"),
                ];
                WQCacheCaptureContainerIdentity(item);
                if (!bid.length || !item.containerIdentityKnown) {
                    item.limited = YES;
                    scanLimited = YES;
                    missingIdentities++;
                }
                item.selected = !item.limited;
                [items addObject:item];
            }
            if (interrupted) break;
        }
        if (!interrupted) {
        if (crashMeasured) {
            // Resuming: the crash-logs section was already measured; reuse it.
            if (crashBytes > 0 || !crashKnown) {
                WQCacheItem *logs = [WQCacheItem new];
                logs.name = @"崩溃日志";
                logs.targets = @[kCrashLogsPath];
                logs.cacheBytes = crashBytes;
                logs.cacheKnown = crashKnown;
                logs.crashLogs = YES;
                logs.limited = !crashKnown;
                logs.targetRecords = @[WQCacheTargetRecordForPath(kCrashLogsPath, nil)];
                logs.selected = !logs.limited;
                [items addObject:logs];
            }
        } else {
        unsigned long long crash = 0;
        // Crash logs are in a system group, which worse_query reaches on iOS 27
        // only. On iOS 26 the section is left out instead of reported as limited.
        BOOL crashReachable = wq_system_areas_reachable();
        BOOL safeCrashPath = crashReachable && WQCacheCrashPathIsSafe(kCrashLogsPath);
        WQCacheMeasurementState crashState = !crashReachable ? WQCacheMeasurementMissing
            : safeCrashPath ? WQCacheMeasureDirectory(kCrashLogsPath, cancellation, &crash)
                            : WQCacheMeasurementLimited;
        if (crashState == WQCacheMeasurementCancelled) {
            interrupted = YES;
        } else {
        if (crashState == WQCacheMeasurementLimited) {
            scanLimited = YES;
            limitedMeasurements++;
        }
        crashMeasured = YES;
        crashBytes = crash;
        crashKnown = crashState != WQCacheMeasurementLimited;
        saveCheckpoint();
        if (crashState == WQCacheMeasurementLimited || crash > 0) {
            WQCacheItem *logs = [WQCacheItem new];
            logs.name = @"崩溃日志";
            logs.targets = @[kCrashLogsPath];
            logs.cacheBytes = crash;
            logs.cacheKnown = crashState != WQCacheMeasurementLimited;
            logs.crashLogs = YES;
            logs.limited = crashState == WQCacheMeasurementLimited;
            logs.targetRecords = @[WQCacheTargetRecordForPath(kCrashLogsPath, nil)];
            logs.selected = !logs.limited;
            [items addObject:logs];
        }
        }
        }
        }
        [items sortUsingComparator:^NSComparisonResult(WQCacheItem *a, WQCacheItem *b) {
            return a.bytes > b.bytes ? NSOrderedAscending : (a.bytes < b.bytes ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSString *> *notes = [NSMutableArray new];
        if (interrupted) {
            scanLimited = YES;
            [notes addObject:@"扫描被中断"];
        }
        if (failedEnumerations) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器枚举失败",
                              (unsigned long)failedEnumerations]];
        }
        if (limitedContainers) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器的访问受限",
                              (unsigned long)limitedContainers]];
        }
        if (limitedMeasurements) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个缓存树测量受限",
                              (unsigned long)limitedMeasurements]];
        }
        if (missingIdentities) {
            [notes addObject:[NSString stringWithFormat:@"%lu 个容器没有标识符或身份",
                              (unsigned long)missingIdentities]];
        }
        NSString *note = nil;
        if (scanLimited) {
            [notes addObject:@"已排除受限的行；其余行仍可清理"];
            note = [NSString stringWithFormat:@"扫描不完整：%@。见日志。", [notes componentsJoinedByString:@"; "]];
        } else if (emptyRoots.count) {
            note = [NSString stringWithFormat:@"未找到 %@ 容器。",
                    [emptyRoots componentsJoinedByString:@"或"]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // A newer scan owns the screen now; only it may publish.
            if (generation != self->_scanGeneration) return;
            // An interrupted scan publishes what it found so far instead of
            // discarding it. And a failed rescan must not wipe a good list:
            // if this scan found nothing because a root enumeration failed
            // but a previous list exists, keep the previous list so the user
            // can still clean instead of landing on 0 KB with greyed-out
            // buttons.
            BOOL keepPrevious = items.count == 0 && failedEnumerations > 0 && self->_items.count > 0;
            if (!keepPrevious) {
                self->_items = items;
            }
            [self rebuildVisibleItems];
            self->_scanning = NO;
            self->_scanLimited = scanLimited;
            self->_status = note;
            self->_lastScanFinished = NSDate.date.timeIntervalSinceReferenceDate;
            [self.refreshControl endRefreshing];
            [self.tableView reloadData];
            [self updateButtons];
            wq_operation_keep_alive_end();
            // A complete scan makes the checkpoint stale; drop it. An
            // interrupted scan keeps it so the next run resumes.
            if (!interrupted) wq_operation_checkpoint_clear(@"cache-scan");
            unsigned long long foundBytes = 0;
            for (WQCacheItem *it in items) foundBytes += it.bytes;
            wq_log(@"cache scan: found %lu items (%@), interrupted=%d, failed enumerations=%lu, kept previous=%d",
                   (unsigned long)items.count, wq_size_text(foundBytes), (int)interrupted,
                   (unsigned long)failedEnumerations, (int)keepPrevious);
            // An interrupted scan leaves a partial list. If the user is still
            // looking at this screen (foreground, view visible) and no clean
            // is running, resume the scan so the list completes instead of
            // sticking at a partial count (e.g. 6 items after the background
            // task expired mid-scan). The resumed run loads the checkpoint
            // and only measures what is left, so it does not start over.
            // Bounded: a scan that keeps being interrupted stops retrying
            // after a few attempts; the user can still pull to refresh. The
            // budget resets on a complete scan and on a user-initiated
            // rescan (see viewWillAppear/userRefresh).
            if (interrupted && !_cleaning && self.view.window &&
                [UIApplication.sharedApplication applicationState] == UIApplicationStateActive) {
                if (self->_interruptedRestarts < 3) {
                    self->_interruptedRestarts++;
                    __weak typeof(self) weakSelf = self;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf || strongSelf->_cleaning || !strongSelf.view.window) return;
                        [strongSelf scan];
                    });
                }
            } else if (!interrupted) {
                self->_interruptedRestarts = 0;
            }
        });
    });
}


#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : (NSInteger)self.visibleItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSUInteger shown = self.visibleItems.count;
    NSUInteger appCount = 0;
    for (WQCacheItem *item in _items) if (!item.crashLogs) appCount++;
    if (!appCount) return @"崩溃日志";
    return _query.length ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)shown, (unsigned long)_items.count]
                         : [NSString stringWithFormat:@"%lu 个应用和扩展", (unsigned long)appCount];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 || !_items.count) return nil;
    NSArray<WQCacheItem *> *selected = [_items filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"selected == YES"]];
    return [WQCacheFooterScope(selected) stringByAppendingString:@" 请先关闭正在运行的应用。"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        WQSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"summary"]
            ?: [[WQSummaryCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"summary"];
        unsigned long long total = 0, selected = 0;
        NSUInteger n = 0;
        for (WQCacheItem *it in _items) { total += it.bytes; if (it.selected) { selected += it.bytes; n++; } }
        BOOL busy = _scanning || _cleaning;
        cell.captionLabel.text = busy ? (_cleaning ? @"正在清理" : @"正在扫描") : @"可回收";
        if (busy) [cell.spinner startAnimating]; else [cell.spinner stopAnimating];
        cell.totalLabel.text = (_scanning && !_items.count) ? @"–" : wq_size_text(total);
        cell.bar.progress = total ? (float)((double)selected / (double)total) : 0;
        cell.bar.hidden = _scanning && !_items.count;
        cell.statusLabel.text = _status ?: _result
            ?: [NSString stringWithFormat:@"%@ 已选，共 %lu 项", wq_size_text(selected), (unsigned long)n];
        return cell;
    }
    WQCleanerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[WQCleanerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"item"];
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    cell.nameLabel.text = item.name;
    if (item.crashLogs) {
        cell.detailLabel.text = item.cacheKnown ? @"崩溃日志 · osanalytics" : @"崩溃日志 · 访问受限";
    } else {
        NSString *cache = item.cacheKnown ? wq_size_text(item.cacheBytes) : @"未知";
        NSString *temp = item.tempKnown ? wq_size_text(item.tempBytes) : @"未知";
        cell.detailLabel.text = [NSString stringWithFormat:@"缓存 %@ · 临时 %@%@", cache, temp,
                                 item.limited ? @" · 访问受限" : @""];
    }
    cell.sizeLabel.text = wq_size_text(item.bytes);
    cell.iconView.image = wq_app_icon(item.bundleID)
        ?: [UIImage systemImageNamed:item.bundleID ? @"app.dashed" : @"exclamationmark.triangle"];
    cell.iconView.tintColor = UIColor.secondaryLabelColor;
    cell.checkView.image = [UIImage systemImageNamed:item.selected ? @"checkmark.circle.fill" : @"circle"];
    cell.checkView.tintColor = item.selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 || _scanning || _cleaning) return;
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    if (item.limited) {
        wq_alert(self, @"无法清理",
                 @"此行的访问或身份信息不完整。请在应用关闭时重新扫描，或通过文件浏览器中的条目查看。");
        return;
    }
    item.selected = !item.selected;
    [tableView reloadRowsAtIndexPaths:@[indexPath, [NSIndexPath indexPathForRow:0 inSection:0]]
                     withRowAnimation:UITableViewRowAnimationNone];
    [self updateButtons];
}

- (void)openFolder:(NSString *)path title:(NSString *)title
{
    [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:title] animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    // Not during a scan or clean: the browser would show a tree that changes underneath it.
    if (indexPath.section == 0 || _scanning || _cleaning) return nil;
    WQCacheItem *item = self.visibleItems[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        NSMutableArray *actions = [NSMutableArray new];
        if (item.crashLogs) {
            NSString *root = item.targets.firstObject;
            [actions addObject:[UIAction actionWithTitle:@"在文件浏览器中显示崩溃日志" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) { [weakSelf openFolder:root title:@"崩溃日志"]; }]];
        } else {
            NSString *caches = item.targets[0], *tmp = item.targets[1];
            [actions addObject:[UIAction actionWithTitle:@"在文件浏览器中显示缓存" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openFolder:caches title:[item.name stringByAppendingString:@" · 缓存"]];
            }]];
            if (item.tempBytes > 0)
                [actions addObject:[UIAction actionWithTitle:@"在文件浏览器中显示 tmp" image:[UIImage systemImageNamed:@"folder"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    [weakSelf openFolder:tmp title:[item.name stringByAppendingString:@" · tmp"]];
                }]];
            [actions addObject:[UIAction actionWithTitle:@"在文件浏览器中显示应用数据" image:[UIImage systemImageNamed:@"folder.badge.gearshape"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                [weakSelf openFolder:caches.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent title:item.name];
            }]];
        }
        return [UIMenu menuWithTitle:item.name children:actions];
    }];
}

#pragma mark Actions

// Applies to the rows the current search shows.
- (void)selectWhere:(BOOL (^)(WQCacheItem *item))rule
{
    for (WQCacheItem *it in self.visibleItems) it.selected = !it.limited && rule(it);
    [self.tableView reloadData];
    [self updateButtons];
}

- (void)stopClean
{
    [_cleanCancellation cancel];
    [self setStatus:@"当前项目完成后停止…"];
}

- (void)confirmClean
{
    NSMutableArray<WQCacheItem *> *selected = [NSMutableArray new];
    unsigned long long sel = 0;
    for (WQCacheItem *item in _items) {
        if (!item.selected) continue;
        [selected addObject:item];
        sel += item.bytes;
    }
    if (!selected.count) return;
    NSString *msg = [NSString stringWithFormat:@"%@，约 %@？此操作无法撤销。请先关闭选中的应用；可在项目之间停止。",
                     WQCacheConfirmationScope(selected), wq_size_text(sel)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理缓存？" message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self clean];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clean
{
    NSArray<WQCacheItem *> *selected = [_items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"selected == YES"]];
    // A fresh clean supersedes any paused one.
    wq_operation_checkpoint_clear(@"cache-clean");
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _cleanCancellation = cancellation;
    _cleaning = YES;
    [self updateButtons];
    [self setStatus:@"正在清理…"];
    // Keep the clean alive if the user switches apps or locks the screen
    // (shared keep-alive, about 30 s of background time). On expiration the
    // clean pauses after the current item and checkpoints its progress, so
    // the next run resumes instead of restarting. Only an explicit user
    // stop cancels.
    wq_operation_keep_alive_begin(@"WQ cache clean");
    dispatch_async(wq_io(), ^{
        unsigned long long freed = 0;
        BOOL allOk = YES;
        BOOL cancelled = NO;
        NSString *validationFailure = nil;
        for (WQCacheItem *item in selected) {
            if (cancellation.isCancelled) { cancelled = YES; break; }
            NSString *reason = nil;
            if (!WQCacheValidateItem(item, &reason)) {
                allOk = NO;
                validationFailure = validationFailure ?: [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"身份已更改"];
                wq_log(@"clean: refusing %@ because %@", item.name, reason ?: @"identity validation failed");
            }
        }
        if (validationFailure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_cleaning = NO;
                self->_cleanCancellation = nil;
                self->_scanLimited = YES;
                self->_cleanRequiresRescan = YES;
                self->_status = nil;
                self->_result = [NSString stringWithFormat:@"清理已取消：%@。请重新扫描后再试。", validationFailure];
                [self.tableView reloadData];
                [self updateButtons];
                wq_operation_keep_alive_end();
            });
            return;
        }
        BOOL paused = NO;
        NSUInteger nextIndex = [self runCleanLoop:selected startIndex:0 freed:&freed allOk:&allOk
                                       cancellation:cancellation paused:&paused
                                    validationFailure:&validationFailure];
        cancelled = cancellation.isCancelled;
        wq_log(@"clean: freed %llu bytes, allOk=%d cancelled=%d paused=%d nextIndex=%lu",
               freed, allOk, cancelled, paused, (unsigned long)nextIndex);
        // Cleaning changes containers below their roots, which the size
        // cache's root-mtime check cannot see: drop the cleaned entries so
        // the rescan in scan measures the emptied caches.
        for (WQCacheItem *item in selected) {
            if (item.containerPath.length) wq_container_size_invalidate(item.containerPath);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishClean:selected freed:freed allOk:allOk paused:paused
                    cancelled:cancelled validationFailure:validationFailure];
        });
    });
}

// Resumes a clean that paused (background time expired, or the app was
// terminated while suspended). Already-cleaned items are skipped; the
// remaining items are cleaned in the same order.
- (void)resumeClean
{
    NSDictionary *checkpoint = wq_operation_checkpoint_load(@"cache-clean");
    if (!checkpoint) return;
    NSMutableArray<WQCacheItem *> *selected = [NSMutableArray new];
    for (NSDictionary *itemDict in [checkpoint[@"items"] isKindOfClass:NSArray.class] ? checkpoint[@"items"] : @[]) {
        WQCacheItem *item = WQCacheItemDecode(itemDict);
        if (!item) continue;
        // A container that changed since the checkpoint is dropped; the
        // rescan after the clean re-measures it.
        if (!item.crashLogs && !WQCacheItemContainerStillAlive(item)) {
            wq_log(@"clean resume: dropping checkpoint item %@ (container changed)", item.name);
            continue;
        }
        [selected addObject:item];
    }
    NSUInteger nextIndex = [checkpoint[@"nextIndex"] unsignedIntegerValue];
    unsigned long long freed = [checkpoint[@"freed"] unsignedLongLongValue];
    BOOL allOk = [checkpoint[@"allOk"] boolValue];
    if (!selected.count || nextIndex >= selected.count) {
        wq_operation_checkpoint_clear(@"cache-clean");
        [self scan];
        return;
    }
    wq_log(@"clean resume: resuming at item %lu/%lu, already freed %@",
           (unsigned long)(nextIndex + 1), (unsigned long)selected.count, wq_size_text(freed));
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _cleanCancellation = cancellation;
    _cleaning = YES;
    [self updateButtons];
    [self setStatus:@"继续清理…"];
    wq_operation_keep_alive_begin(@"WQ cache clean (resume)");
    dispatch_async(wq_io(), ^{
        BOOL paused = NO;
        NSString *validationFailure = nil;
        NSUInteger next = [self runCleanLoop:selected startIndex:nextIndex freed:&freed allOk:&allOk
                                  cancellation:cancellation paused:&paused
                               validationFailure:&validationFailure];
        BOOL cancelled = cancellation.isCancelled;
        wq_log(@"clean resume: freed %llu bytes total, allOk=%d cancelled=%d paused=%d nextIndex=%lu",
               freed, allOk, cancelled, paused, (unsigned long)next);
        for (WQCacheItem *item in selected) {
            if (item.containerPath.length) wq_container_size_invalidate(item.containerPath);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishClean:selected freed:freed allOk:allOk paused:paused
                    cancelled:cancelled validationFailure:validationFailure];
        });
    });
}

// Runs the clean loop on the calling (worker) thread, starting at
// startIndex. Returns the index of the next unprocessed item; *paused is
// set when the background time expired (a checkpoint was saved, so the
// next run resumes at the returned index). *freed/*allOk accumulate across
// a resume. Must be called on a worker queue, never the main thread.
- (NSUInteger)runCleanLoop:(NSArray<WQCacheItem *> *)selected
                startIndex:(NSUInteger)startIndex
                     freed:(unsigned long long *)freedPtr
                     allOk:(BOOL *)allOkPtr
              cancellation:(WQScanCancellation *)cancellation
                    paused:(BOOL *)pausedPtr
         validationFailure:(NSString **)validationFailurePtr
{
    *pausedPtr = NO;
    NSUInteger i = startIndex;
    NSUInteger sinceCheckpoint = 0;
    for (; i < selected.count; i++) {
        WQCacheItem *item = selected[i];
        if (cancellation.isCancelled) break;
        // Background time expired: pause instead of cancelling. The
        // checkpoint below holds the progress, so the next run resumes at
        // this item instead of starting over.
        if (wq_operation_background_expiring()) {
            *pausedPtr = YES;
            wq_operation_clear_background_expiring();
            break;
        }
        NSUInteger shown = i + 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setStatus:[NSString stringWithFormat:@"正在清理 %lu/%lu：%@",
                             (unsigned long)shown, (unsigned long)selected.count, item.name]];
        });
        for (WQCacheTargetRecord *record in item.targetRecords) {
            if (cancellation.isCancelled) break;
            NSString *reason = nil;
            if (!WQCacheValidateItem(item, &reason)) {
                *allOkPtr = NO;
                if (validationFailurePtr) *validationFailurePtr = [NSString stringWithFormat:@"%@ (%@)", item.name, reason ?: @"身份已更改"];
                wq_log(@"clean: stopped before %@ because %@", record.path, reason ?: @"identity validation failed");
                break;
            }
            if (!wq_purge_contents_cancellable(record.path, freedPtr, cancellation)) {
                *allOkPtr = NO;
                if (cancellation.isCancelled) break;
            }
        }
        if (*validationFailurePtr || cancellation.isCancelled || *pausedPtr) break;
        // This item is done. Checkpoint every 10 items so a termination
        // while suspended loses at most 10 items of progress.
        sinceCheckpoint++;
        if (sinceCheckpoint >= 10) {
            sinceCheckpoint = 0;
            WQCacheSaveCleanCheckpoint(selected, i + 1, *freedPtr, *allOkPtr);
        }
    }
    // Paused: save the checkpoint at the item we stopped before.
    if (*pausedPtr) WQCacheSaveCleanCheckpoint(selected, i, *freedPtr, *allOkPtr);
    return i;
}

// Shared completion for clean and resumeClean. Must be called on the main
// queue. Ends the keep-alive; clears the checkpoint except when paused
// (a pause keeps it so the next run resumes).
- (void)finishClean:(NSArray<WQCacheItem *> *)selected
              freed:(unsigned long long)freed
              allOk:(BOOL)allOk
             paused:(BOOL)paused
           cancelled:(BOOL)cancelled
  validationFailure:(NSString *)validationFailure
{
    self->_cleaning = NO;
    self->_cleanCancellation = nil;
    if (paused) {
        // Paused, not cancelled: the checkpoint holds the progress.
        // Resumes automatically when the user returns to this page
        // (viewWillAppear/viewDidLoad), or when they tap clean again.
        self->_status = [NSString stringWithFormat:@"已暂停，已释放 %@，返回后继续清理…", wq_size_text(freed)];
        self->_result = [NSString stringWithFormat:@"已暂停：已释放 %@。切回本页后自动继续。", wq_size_text(freed)];
        [self.tableView reloadData];
        [self updateButtons];
        wq_operation_keep_alive_end();
        return;
    }
    // Done, cancelled, or validation-failed: no resume.
    wq_operation_checkpoint_clear(@"cache-clean");
    if (cancelled) {
        self->_status = nil;
        [self scan];
        self->_result = [NSString stringWithFormat:@"已停止。已释放 %@。%@", wq_size_text(freed),
                         allOk ? @"" : @" 有些项目无法删除（见日志）。"];
        wq_operation_keep_alive_end();
        return;
    }
    if (validationFailure) {
        self->_scanLimited = YES;
        self->_cleanRequiresRescan = YES;
        self->_status = nil;
        self->_result = [NSString stringWithFormat:@"清理已停止：%@。请重新扫描后再试。", validationFailure];
        [self.tableView reloadData];
        [self updateButtons];
    } else {
        self->_status = nil;
        [self scan];
        self->_result = [NSString stringWithFormat:@"已释放 %@。%@", wq_size_text(freed),
                         allOk ? @"" : @" 有些项目无法删除（见日志）。"];
    }
    wq_operation_keep_alive_end();
}

@end
