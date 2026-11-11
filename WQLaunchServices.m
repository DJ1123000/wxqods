//
//  WQLaunchServices.m
//  WQ Files
//  GPL-3.0-or-later.
//

#import "WQLaunchServices.h"
#import "WQAccess.h"
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

#pragma mark - App names from the LaunchServices database

// LaunchServices' own API refuses this app on 27.x (OSStatus -54) and the app
// bundles cannot be opened, but lsd keeps its database (CSStore2, magic
// "bdsl") in an Internal Daemon container that we can read. In it, Bundle
// records are 0x250 bytes long, preceded by [u32][u32 0x250]: +0x0c bundle
// id, +0x6c bundle name, +0x74 display name, each a string reference
// (string id << 2). Strings are stored as [u32 id][u32 length][UTF-8][NUL].
// Names that exist only in localized form (most Apple apps) are not decoded;
// the built-in table below covers those.

static NSString *const kWQLSStoreKey = @"WQLaunchServicesStore";
// When the database wasn't found: don't search again for a day (each search
// lists every daemon container), unless the user refreshes.
static NSString *const kWQLSMissKey = @"WQLaunchServicesStoreMissedAt";
static const NSTimeInterval kWQLSMissRetry = 24 * 60 * 60;

// These limits keep a malformed or unexpectedly large database from turning a
// synchronous display-name lookup into an unbounded read/parse operation.
static const size_t kWQLSMinStoreBytes = 0x1000;
static const size_t kWQLSMaxStoreBytes = 64u * 1024u * 1024u;
static const uint32_t kWQLSMaxStringID = 0x01000000u;
static const NSUInteger kWQLSMaxBundleRecords = 100000;
static const NSUInteger kWQLSMaxDecodedStrings = 200000;
static const NSUInteger kWQLSMaxDecodedStringBytes = 8u * 1024u * 1024u;

static NSObject *wq_ls_lock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// The regression tests still exercise discovery through the daemon list.
#ifdef WQ_LS_TESTING
static BOOL wq_ls_test_daemon_search = YES;
#else
static const BOOL wq_ls_test_daemon_search = NO;
#endif

static NSString *wq_find_ls_store(BOOL *searched);
static BOOL wq_ls_candidate_info(NSString *path, struct stat *st);

static BOOL wq_ls_stat_equal(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
        a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec;
}

static NSDictionary *wq_ls_signature(const struct stat *st)
{
    return @{
        @"device": @(st->st_dev), @"inode": @(st->st_ino), @"size": @(st->st_size),
        @"modifiedSeconds": @(st->st_mtimespec.tv_sec),
        @"modifiedNanoseconds": @(st->st_mtimespec.tv_nsec)
    };
}

static BOOL wq_ls_signature_equal(NSDictionary *a, NSDictionary *b)
{
    return a && b && [a isEqualToDictionary:b];
}

static NSString *wq_ls_error(NSString *path, NSString *reason)
{
    return [NSString stringWithFormat:@"%@ (%@)", path ?: @"<none>", reason ?: @"未知错误"];
}

static BOOL wq_ls_candidate_info(NSString *path, struct stat *st)
{
    if (!path.length || !wq_stat(path, st) || !S_ISREG(st->st_mode) ||
        st->st_size < (off_t)kWQLSMinStoreBytes || st->st_size > (off_t)kWQLSMaxStoreBytes) {
        return NO;
    }
    NSString *error = nil;
    NSData *header = wq_read(path, 4, &error);
    if (header.length != 4 || memcmp(header.bytes, "bdsl", 4) != 0) return NO;
    return YES;
}

static BOOL wq_ls_is_newer(NSString *path, const struct stat *st,
                           NSString *bestPath, const struct stat *best)
{
    if (!bestPath) return YES;
    if (st->st_mtimespec.tv_sec != best->st_mtimespec.tv_sec)
        return st->st_mtimespec.tv_sec > best->st_mtimespec.tv_sec;
    if (st->st_mtimespec.tv_nsec != best->st_mtimespec.tv_nsec)
        return st->st_mtimespec.tv_nsec > best->st_mtimespec.tv_nsec;
    if (st->st_size != best->st_size) return st->st_size > best->st_size;
    return [path compare:bestPath] == NSOrderedAscending;
}

static void wq_ls_consider_candidate(NSString *path, NSString **bestPath,
                                      struct stat *best, NSMutableSet<NSString *> *seen)
{
    if (!path.length || [seen containsObject:path]) return;
    [seen addObject:path];

    struct stat st;
    if (!wq_ls_candidate_info(path, &st)) return;
    if (wq_ls_is_newer(path, &st, *bestPath, best)) {
        *bestPath = path;
        *best = st;
    }
}

// *searched: the daemon containers were actually listed (a failed or cancelled
// scan says nothing about whether the database exists).
static NSString *wq_find_ls_store(BOOL *searched)
{
    if (searched) *searched = NO;
    NSString *cached = [NSUserDefaults.standardUserDefaults stringForKey:kWQLSStoreKey];
    NSString *bestPath = nil;
    struct stat best = {0};
    struct stat cachedStat;
    BOOL cachedValid = cached.length && wq_ls_candidate_info(cached, &cachedStat);
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (cachedValid) wq_ls_consider_candidate(cached, &bestPath, &best, seen);

    // Listing the daemon containers is a full id scan (minutes, and it asks
    // first); the database is found by the container scan among the newest
    // ids and remembered, so names only use the remembered location.
    if (!wq_ls_test_daemon_search) {
        if (searched) *searched = cachedValid;
        return cachedValid ? cached : nil;
    }
    NSArray *daemons = wq_enumerate(@"/private/var/mobile/Containers/Data/InternalDaemon", 0, nil, nil);
    if (daemons && searched) *searched = YES;
    if (daemons) {
        for (NSString *container in daemons) {
            NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
            NSArray *items = wq_list(caches, NULL);
            for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
                if (![name hasPrefix:@"com.apple.LaunchServices-"] || ![name hasSuffix:@".csstore"]) continue;
                wq_ls_consider_candidate([caches stringByAppendingPathComponent:name], &bestPath, &best, seen);
            }
        }
    }

    // Keep a valid cached path usable if enumeration is temporarily unavailable.
    if (!bestPath && cachedValid) {
        bestPath = cached;
    }
    return bestPath;
}

// Record layouts by release. Offsets are from the record body (after the
// 8-byte header). iOS 26 records are 0x14 bytes shorter, with the container
// path and the fields after it 4 bytes earlier than on 27.0.
typedef struct {
    const char *label;
    uint32_t bundleSize, bundleID, container, name, displayName, bundlePath;
    uint32_t pluginSize, pluginBundleID, pluginContainer;
} WQLSLayout;
static const WQLSLayout kWQLSLayouts[] = {
    { "27.0", 0x250, 0x0c, 0x68, 0x6c, 0x74, 0x00, 0x118, 0x00, 0x54 },
    { "26",   0x23c, 0x0c, 0x64, 0x68, 0x70, 0x00, 0x104, 0x00, 0x50 },
    // iOS 27.2 (from a device's layout hint): container fields 4 bytes later
    // than on 27.0. Whether the bundle id moved too isn't known yet, so both
    // positions are tried; the one that maps the most containers wins.
    { "27.2", 0x25c, 0x0c, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x00, 0x58 },
    { "27.2b", 0x25c, 0x10, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x04, 0x58 },
    { "27.2c", 0x25c, 0x0c, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x04, 0x58 },
    { "27.2d", 0x25c, 0x10, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x00, 0x58 },
};
static const size_t kWQLSLayoutCount = sizeof(kWQLSLayouts) / sizeof(kWQLSLayouts[0]);
static const size_t kWQLSMaxRecordSize = 0x25c;

static uint32_t wq_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static NSString *wq_cs_string(const uint8_t *b, size_t n, size_t o)
{
    if (o > n || n - o < 8) return nil;
    uint32_t len = wq_rd32(b + o + 4);
    // Strings are padded with zero bytes to a multiple of 4. One whose length
    // is already a multiple of 4 has no terminator (container paths are 84 or
    // 88 bytes), so only shorter ones must end in a zero byte. A string must
    // still end before the buffer does.
    if (len == 0 || len >= 0x800 || len >= n - o - 8 || (len % 4 && b[o + 8 + len] != 0)) return nil;
    if (memchr(b + o + 8, 0, len)) return nil;
    NSString *s = [[NSString alloc] initWithBytes:b + o + 8 length:len encoding:NSUTF8StringEncoding];
    return s;
}

static BOOL wq_looks_like_bundle_id(NSString *s)
{
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    return s.length > 2 && [s containsString:@"."] && ![s hasPrefix:@"."]
        && [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

// Unicode format characters include bidi overrides/isolates, zero-width
// characters, and BOM-like markers. They are replaced visibly while ordinary
// international letters, accents, and scripts remain unchanged.
static BOOL wq_is_name_format_scalar(uint32_t c)
{
    return c == 0x00ad || (c >= 0x0600 && c <= 0x0605) || c == 0x061c || c == 0x06dd ||
        c == 0x070f || (c >= 0x0890 && c <= 0x0891) || c == 0x08e2 || c == 0x180e ||
        (c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e) ||
        (c >= 0x2060 && c <= 0x206f) || c == 0xfeff;
}

static NSString *wq_safe_name(NSString *value)
{
    if (!value.length) return nil;
    NSMutableString *safe = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length;) {
        uint32_t scalar = [value characterAtIndex:i++];
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (i >= value.length) return nil;
            unichar low = [value characterAtIndex:i++];
            if (low < 0xdc00 || low > 0xdfff) return nil;
            scalar = 0x10000u + ((scalar - 0xd800u) << 10) + (low - 0xdc00u);
        } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
            return nil;
        }

        if (wq_is_name_format_scalar(scalar) || scalar == 0x2028 || scalar == 0x2029) {
            [safe appendString:@"\uFFFD"];
        } else if (scalar <= 0xffff) {
            [safe appendFormat:@"%C", (unichar)scalar];
        } else {
            scalar -= 0x10000u;
            [safe appendFormat:@"%C%C", (unichar)(0xd800u + (scalar >> 10)),
             (unichar)(0xdc00u + (scalar & 0x3ffu))];
        }
    }

    NSString *normalized = [safe precomposedStringWithCanonicalMapping];
    normalized = [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!normalized.length || [normalized hasPrefix:@"/"] || [normalized containsString:@".app/"]) return nil;
    if ([normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return normalized;
}

// Data container path -> bundle id. Apps: the Bundle record's +0x68 field;
// extensions: 0x118-byte plugin records with the bundle id at +0x00 and the
// path at +0x54. On iOS 27.2 the containers' identifier attribute can't be
// read, so this is how their folders get a bundle id (and a name).
static BOOL wq_is_data_container_path(NSString *path)
{
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"/private/var/mobile/Containers/Data/Application/",
                     @"/private/var/mobile/Containers/Data/PluginKitPlugin/"];
    });
    for (NSString *prefix in prefixes) {
        if (![path hasPrefix:prefix] || path.length != prefix.length + 36) continue;
        return [[NSUUID alloc] initWithUUIDString:[path substringFromIndex:prefix.length]] != nil;
    }
    return NO;
}

// Diagnostics: how many container paths the store holds, and which record
// sizes and offsets refer to them. Only sizes and offsets are logged (no
// names), so a Log from a release with a new layout shows where it moved.
static int wq_u32_cmp(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

static void wq_ls_log_summary(const uint8_t *b, size_t n, NSString *layout, NSUInteger bundleRecords,
                              NSUInteger pluginRecords, NSUInteger names, NSUInteger mapped)
{
    NSMutableData *refData = [NSMutableData new];
    static const char needle[] = "/var/mobile/Containers/Data/";
    const size_t needleLen = sizeof(needle) - 1;
    const uint8_t *cursor = b, *end = b + n;
    while (cursor < end) {
        const uint8_t *hit = memmem(cursor, (size_t)(end - cursor), needle, needleLen);
        if (!hit) break;
        cursor = hit + needleLen;
        const uint8_t *start = hit;
        if ((size_t)(hit - b) >= 8 && memcmp(hit - 8, "/private", 8) == 0) start = hit - 8;
        size_t o = (size_t)(start - b);
        if (o < 8 || o % 4) continue;
        uint32_t len = wq_rd32(start - 4);
        if (len < needleLen || len > 0x100 || len > (size_t)(end - start)) continue;
        uint32_t ref = wq_rd32(start - 8) << 2;
        if (ref) [refData appendBytes:&ref length:sizeof(ref)];
        if (refData.length / sizeof(uint32_t) >= 20000) break;
    }
    NSUInteger pathCount = refData.length / sizeof(uint32_t);
    uint32_t *refs = refData.mutableBytes;
    if (pathCount) qsort(refs, pathCount, sizeof(uint32_t), wq_u32_cmp);
    wq_log(@"names: store %.1f MB, layout %@: %lu bundle and %lu plugin records, %lu names, %lu of %lu container paths mapped",
           n / 1048576.0, layout, (unsigned long)bundleRecords, (unsigned long)pluginRecords, (unsigned long)names,
           (unsigned long)mapped, (unsigned long)pathCount);
    if (!pathCount || mapped * 2 >= pathCount) return;

    // Vote for (record size, offset of the container reference).
    NSCountedSet<NSNumber *> *votes = [NSCountedSet new];
    for (size_t q = 0; q + 4 <= n; q += 4) {
        uint32_t v = wq_rd32(b + q);
        if (!v || (v & 3) || !bsearch(&v, refs, pathCount, sizeof(uint32_t), wq_u32_cmp)) continue;
        for (size_t k = 0; k < 0x400 && q >= 8 + k; k += 4) {
            uint32_t size = wq_rd32(b + q - 8 - k + 4);
            if (size >= 0x40 && size <= 0x800 && size % 4 == 0 && k < size)
                [votes addObject:@((uint64_t)size << 16 | k)];
        }
    }
    NSArray *top = [votes.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
        NSUInteger cx = [votes countForObject:x], cy = [votes countForObject:y];
        return cx > cy ? NSOrderedAscending : cx < cy ? NSOrderedDescending : [x compare:y];
    }];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSNumber *key in [top subarrayWithRange:NSMakeRange(0, MIN(top.count, (NSUInteger)8))]) {
        uint64_t value = key.unsignedLongLongValue;
        [parts addObject:[NSString stringWithFormat:@"0x%llx@0x%llx x%lu", value >> 16, value & 0xffff,
                          (unsigned long)[votes countForObject:key]]];
    }
    wq_log(@"names: layout hint (record size@container offset): %@", [parts componentsJoinedByString:@", "]);
}

// Distinct record sizes in kWQLSLayouts (bundle and plug-in). Pass 1 used to
// step every 4 bytes over the whole file and test six layouts at each offset
// (~100M iterations at 64MB). A record header is [u32][u32 size], so the
// size words can be found with memmem first and only those offsets
// validated. The per-size streams below are merged in file order, so the
// records are collected exactly as the old scan collected them.
static const uint32_t kWQLSRecordSizes[] = { 0x250, 0x23c, 0x25c, 0x118, 0x104, 0x120 };
enum { kWQLSRecordSizeCount = 6 };
_Static_assert(sizeof(kWQLSRecordSizes) / sizeof(kWQLSRecordSizes[0]) == kWQLSRecordSizeCount,
               "record size table mismatch");

// Find the next record at or after *cursor whose size word equals size.
// On success *cursor advances past the hit and *outOffset is the record
// start (o, with the size at o+4). Otherwise NO and this size is exhausted:
// later hits would only be further out, past the loop bound. The store is
// little-endian, as is the host, so the size word can be memmem'd directly.
static BOOL wq_ls_next_record(const uint8_t *b, size_t n, uint32_t size,
                              const uint8_t **cursor, size_t *outOffset)
{
    const uint8_t *end = b + n;
    while (*cursor < end) {
        const uint8_t *hit = memmem(*cursor, (size_t)(end - *cursor), &size, sizeof(size));
        if (!hit) { *cursor = end; return NO; }
        *cursor = hit + 1;
        if (hit < b + 4) continue;
        size_t o = (size_t)(hit - b) - 4;
        if (o % 4) continue;
        if (o + 8 + kWQLSMaxRecordSize > n) { *cursor = end; return NO; }
        *outOffset = o;
        return YES;
    }
    return NO;
}

static BOOL wq_parse_ls_store(NSData *data, NSDictionary **displayOut,
                              NSDictionary **bundleNameOut, NSDictionary **containersOut,
                              NSDictionary **bundlePathsOut)
{
    if (bundlePathsOut) *bundlePathsOut = nil;
    if (displayOut) *displayOut = nil;
    if (bundleNameOut) *bundleNameOut = nil;
    if (containersOut) *containersOut = nil;

    const uint8_t *b = data.bytes;
    size_t n = data.length;
    if (n < kWQLSMinStoreBytes || !b || memcmp(b, "bdsl", 4) != 0) {
        wq_log(@"names: not a LaunchServices store");
        return NO;
    }
    NSRange heapRange = [data rangeOfData:[NSData dataWithBytes:"<string>" length:8]
                                  options:0 range:NSMakeRange(0, n)];
    size_t heap = heapRange.location == NSNotFound ? 0 : heapRange.location;

    // Pass 1: Bundle and plug-in records of every known layout, and which
    // string ids they need. The layout that maps the most containers wins.
    const uint32_t kIDs = kWQLSMaxStringID;
    size_t bitsetBytes = kIDs / 8;
    uint8_t *need = calloc(bitsetBytes, 1), *inHeap = calloc(bitsetBytes, 1);
    NSMutableArray<NSMutableData *> *layoutRecs = [NSMutableArray new], *layoutPlugins = [NSMutableArray new];
    for (size_t l = 0; l < kWQLSLayoutCount; l++) {
        [layoutRecs addObject:[NSMutableData new]];
        [layoutPlugins addObject:[NSMutableData new]];   // pairs: bundle id ref, container path ref
    }
    if (!need || !inHeap) {
        free(need);
        free(inHeap);
        wq_log(@"names: LaunchServices parser allocation failed");
        return NO;
    }

    BOOL tooManyRecords = NO;
    // Merge the per-size candidate streams in file order; each candidate
    // offset is validated exactly as the old step-4 scan validated it.
    const uint8_t *cursors[kWQLSRecordSizeCount];
    size_t nextOffset[kWQLSRecordSizeCount];
    BOOL hasNext[kWQLSRecordSizeCount];
    for (size_t s = 0; s < kWQLSRecordSizeCount; s++) {
        cursors[s] = b + 4;
        hasNext[s] = wq_ls_next_record(b, n, kWQLSRecordSizes[s], &cursors[s], &nextOffset[s]);
    }
    while (!tooManyRecords) {
        size_t sizeIdx = kWQLSRecordSizeCount, o = 0;
        for (size_t s = 0; s < kWQLSRecordSizeCount; s++) {
            if (!hasNext[s]) continue;
            if (sizeIdx == kWQLSRecordSizeCount || nextOffset[s] < o) { sizeIdx = s; o = nextOffset[s]; }
        }
        if (sizeIdx == kWQLSRecordSizeCount) break;
        hasNext[sizeIdx] = wq_ls_next_record(b, n, kWQLSRecordSizes[sizeIdx], &cursors[sizeIdx], &nextOffset[sizeIdx]);
        uint32_t size = wq_rd32(b + o + 4);
        const uint8_t *u = b + o + 8;
        for (size_t l = 0; l < kWQLSLayoutCount; l++) {
            const WQLSLayout *L = &kWQLSLayouts[l];
            if (size == L->pluginSize) {
                NSMutableData *plugins = layoutPlugins[l];
                uint32_t p[2] = { wq_rd32(u + L->pluginBundleID), wq_rd32(u + L->pluginContainer) };
                if (p[0] && !(p[0] & 3) && (p[0] >> 2) < kIDs && p[1] && !(p[1] & 3) && (p[1] >> 2) < kIDs &&
                    plugins.length / sizeof(p) < kWQLSMaxBundleRecords) {
                    [plugins appendBytes:p length:sizeof(p)];
                    for (int i = 0; i < 2; i++) need[(p[i] >> 2) / 8] |= 1 << ((p[i] >> 2) % 8);
                }
            }
            if (size != L->bundleSize) continue;
            NSMutableData *recs = layoutRecs[l];
            if (recs.length / (5 * sizeof(uint32_t)) >= kWQLSMaxBundleRecords) {
                tooManyRecords = YES;
                break;
            }
            uint32_t r[5] = { wq_rd32(u + L->bundleID), wq_rd32(u + L->name), wq_rd32(u + L->displayName), wq_rd32(u + L->container),
                              wq_rd32(u + L->bundlePath) };
            if (!r[0] || (r[0] & 3) || (r[0] >> 2) >= kIDs) continue;
            [recs appendBytes:r length:sizeof(r)];
            for (int i = 0; i < 5; i++) {
                if (r[i] && !(r[i] & 3) && (r[i] >> 2) < kIDs)
                    need[(r[i] >> 2) / 8] |= 1 << ((r[i] >> 2) % 8);
            }
        }
    }
    if (tooManyRecords) {
        free(need);
        free(inHeap);
        wq_log(@"names: LaunchServices store exceeds record limit");
        return NO;
    }

    // Pass 2: the strings, preferring copies inside the string table. On
    // iOS 26 container paths live in a second table whose ids overlap the
    // string table's, so path-shaped strings are also kept by id on their own
    // (an id with two different paths is unusable).
    NSMutableDictionary<NSNumber *, NSString *> *strings = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, id> *pathStrings = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, id> *appPathStrings = [NSMutableDictionary new];
    NSUInteger decodedStringBytes = 0;
    BOOL tooManyStrings = NO;
    for (size_t o = 0; o <= n - 8; o += 4) {
        uint32_t sid = wq_rd32(b + o);
        if (!sid || sid >= kIDs || !(need[sid / 8] & (1 << (sid % 8)))) continue;
        BOOL here = o >= heap, had = strings[@(sid)] != nil;
        BOOL keepGeneral = !had || (here && !(inHeap[sid / 8] & (1 << (sid % 8))));
        uint32_t peekLen = o + 8 <= n ? wq_rd32(b + o + 4) : 0;
        BOOL maybePath = peekLen >= 6 && peekLen < 0x400 && o + 8 < n && b[o + 8] == '/';
        if (!keepGeneral && !maybePath) continue;
        NSString *s = wq_cs_string(b, n, o);
        if (!s) continue;
        if (maybePath) {
            NSMutableDictionary *table = [s containsString:@"/mobile/Containers/Data/"] ? pathStrings
                : ([s hasSuffix:@".app"] || [s hasSuffix:@".app/"]) ? appPathStrings : nil;
            id previous = table[@(sid)];
            if (table && !previous) table[@(sid)] = s;
            else if (table && ![previous isEqual:s]) table[@(sid)] = NSNull.null;
        }
        if (!keepGeneral) continue;
        if (!had && (strings.count >= kWQLSMaxDecodedStrings ||
                     s.length > kWQLSMaxDecodedStringBytes - decodedStringBytes)) {
            tooManyStrings = YES;
            break;
        }
        strings[@(sid)] = s;
        if (!had) decodedStringBytes += s.length;
        if (here) inHeap[sid / 8] |= 1 << (sid % 8);
    }
    free(need);
    free(inHeap);
    if (tooManyStrings) {
        wq_log(@"names: LaunchServices store exceeds string limit");
        return NO;
    }
    NSUInteger anyRecords = 0, anyPlugins = 0;
    for (size_t l = 0; l < kWQLSLayoutCount; l++) {
        anyRecords += layoutRecs[l].length / (5 * sizeof(uint32_t));
        anyPlugins += layoutPlugins[l].length / (2 * sizeof(uint32_t));
    }
    if (!anyRecords) {
        wq_ls_log_summary(b, n, @"none", 0, anyPlugins, 0, 0);
        wq_log(@"names: LaunchServices store contains no bundle records");
        return NO;
    }

    NSString *(^pathFor)(uint32_t) = ^NSString *(uint32_t ref) {
        id path = pathStrings[@(ref >> 2)];
        if (path == NSNull.null) return nil;
        return path ?: strings[@(ref >> 2)];
    };
    NSDictionary *display = nil, *bundleName = nil, *containers = nil, *bundlePaths = nil;
    size_t chosen = 0;
    for (size_t l = 0; l < kWQLSLayoutCount; l++) {
        NSMutableDictionary *layoutDisplay = [NSMutableDictionary new], *layoutBundleName = [NSMutableDictionary new];
        NSMutableDictionary *layoutBundlePaths = [NSMutableDictionary new];
        NSMutableDictionary<NSString *, id> *layoutContainers = [NSMutableDictionary new];
        // A path claimed by two different bundle ids is left out rather than guessed.
        // Plug-in records only claim extension containers and bundle records
        // only app containers, so a record type that happens to share a size
        // can't knock out the other table's paths.
        void (^claim)(NSString *, NSString *, NSString *) = ^(NSString *path, NSString *bid, NSString *kind) {
            // iOS 26 stores container paths with a trailing slash; lookups
            // use the /private/var form without one.
            if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
            if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
            if (!wq_is_data_container_path(path) || !wq_looks_like_bundle_id(bid) || ![path containsString:kind]) return;
            id known = layoutContainers[path];
            if (!known) layoutContainers[path] = bid;
            else if (![known isEqual:bid]) layoutContainers[path] = NSNull.null;
        };
        NSData *plugins = layoutPlugins[l], *recs = layoutRecs[l];
        const uint32_t *pr = plugins.bytes;
        for (NSUInteger i = 0; i < plugins.length / sizeof(uint32_t); i += 2)
            claim(pathFor(pr[i + 1]), strings[@(pr[i] >> 2)], @"/Data/PluginKitPlugin/");
        const uint32_t *r = recs.bytes;
        for (NSUInteger i = 0; i < recs.length / sizeof(uint32_t); i += 5) {
            NSString *bid = strings[@(r[i] >> 2)];
            if (!wq_looks_like_bundle_id(bid)) continue;
            if (r[i + 3] && !(r[i + 3] & 3)) claim(pathFor(r[i + 3]), bid, @"/Data/Application/");
            NSString *nm = (r[i + 1] & 3) ? nil : strings[@(r[i + 1] >> 2)];
            NSString *dn = (r[i + 2] & 3) ? nil : strings[@(r[i + 2] >> 2)];
            NSString *safeDisplay = wq_safe_name(dn);
            NSString *safeBundleName = wq_safe_name(nm);
            if (safeDisplay && !layoutDisplay[bid]) layoutDisplay[bid] = safeDisplay;
            if (safeBundleName && !layoutBundleName[bid]) layoutBundleName[bid] = safeBundleName;
            id appPath = (r[i + 4] && !(r[i + 4] & 3)) ? appPathStrings[@(r[i + 4] >> 2)] : nil;
            if ([appPath isKindOfClass:NSString.class] && !layoutBundlePaths[bid]) {
                NSString *clean = [appPath hasSuffix:@"/"] ? [appPath substringToIndex:[appPath length] - 1] : appPath;
                if ([clean hasPrefix:@"/var/"]) clean = [@"/private" stringByAppendingString:clean];
                layoutBundlePaths[bid] = clean;
            }
        }
        for (NSString *path in layoutContainers.allKeys)
            if (layoutContainers[path] == NSNull.null) [layoutContainers removeObjectForKey:path];
        if (!containers || layoutContainers.count > containers.count ||
            (layoutContainers.count == containers.count && layoutDisplay.count > display.count)) {
            display = layoutDisplay;
            bundleName = layoutBundleName;
            bundlePaths = layoutBundlePaths;
            containers = layoutContainers;
            chosen = l;
        }
    }
    // A few Apple apps' names, to check the name fields of a new layout.
    NSMutableArray *samples = [NSMutableArray new];
    for (NSString *bid in @[@"com.apple.mobilesafari", @"com.apple.Preferences", @"com.apple.camera", @"com.apple.mobilenotes"]) {
        NSString *name = display[bid] ?: bundleName[bid];
        if (name) [samples addObject:[NSString stringWithFormat:@"%@ = %@", bid, name]];
    }
    // The container scan and the name loader each parse the same store; log
    // its summary once per distinct result, not once per parse.
    static NSString *lastSummary;
    NSString *summary = [NSString stringWithFormat:@"%zu %zu %lu %lu", n, chosen, (unsigned long)display.count,
                         (unsigned long)containers.count];
    BOOL newSummary;
    @synchronized (NSObject.class) {
        newSummary = ![summary isEqualToString:lastSummary];
        if (newSummary) lastSummary = summary;
    }
    if (newSummary && samples.count) wq_log(@"names: sample: %@", [samples componentsJoinedByString:@", "]);
    if (newSummary) wq_ls_log_summary(b, n, @(kWQLSLayouts[chosen].label), layoutRecs[chosen].length / (5 * sizeof(uint32_t)),
                      layoutPlugins[chosen].length / (2 * sizeof(uint32_t)), display.count, containers.count);
    if (bundlePathsOut) *bundlePathsOut = [bundlePaths copy];
    if (displayOut) *displayOut = [display copy];
    if (bundleNameOut) *bundleNameOut = [bundleName copy];
    if (containersOut) *containersOut = [containers copy];
    return YES;
}

// One immutable snapshot, shared by the names path and the container
// listing: a single parse of a store version publishes the display names,
// bundle names, container map, bundle paths, and the container paths
// (mapped containers plus AppGroup containers found in the same data).
// Readers only ever hold a pointer to a snapshot, never the globals, so a
// snapshot can be published atomically and the previous one stays usable
// until then. The signature is the store's (device, inode, size, mtime)
// from wq_ls_signature; a store is re-parsed only when it changes.
@interface WQLSSnapshot : NSObject
@property (nonatomic, copy, readonly) NSDictionary *display;
@property (nonatomic, copy, readonly) NSDictionary *bundleName;
@property (nonatomic, copy, readonly) NSDictionary *containers;
@property (nonatomic, copy, readonly) NSDictionary *bundlePaths;
@property (nonatomic, copy, readonly) NSArray<NSString *> *containerPaths;
@property (nonatomic, copy, readonly) NSString *storePath;
@property (nonatomic, copy, readonly) NSDictionary *signature;
- (instancetype)initWithDisplay:(NSDictionary *)display
                     bundleName:(NSDictionary *)bundleName
                     containers:(NSDictionary *)containers
                    bundlePaths:(NSDictionary *)bundlePaths
                 containerPaths:(NSArray<NSString *> *)containerPaths
                      storePath:(NSString *)storePath
                      signature:(NSDictionary *)signature;
@end

@implementation WQLSSnapshot
- (instancetype)initWithDisplay:(NSDictionary *)display
                     bundleName:(NSDictionary *)bundleName
                     containers:(NSDictionary *)containers
                    bundlePaths:(NSDictionary *)bundlePaths
                 containerPaths:(NSArray<NSString *> *)containerPaths
                      storePath:(NSString *)storePath
                      signature:(NSDictionary *)signature
{
    if ((self = [super init])) {
        _display = [display copy] ?: @{};
        _bundleName = [bundleName copy] ?: @{};
        _containers = [containers copy] ?: @{};
        _bundlePaths = [bundlePaths copy] ?: @{};
        _containerPaths = [containerPaths copy] ?: @[];
        _storePath = [storePath copy];
        _signature = [signature copy];
    }
    return self;
}
@end

static WQLSSnapshot *gLSSnapshot;
static NSUInteger gLSFailureCount;
static NSTimeInterval gLSNextRetryAt;

// Call with wq_ls_lock() held.
static void wq_ls_note_failure(NSTimeInterval now, NSString *reason)
{
    gLSFailureCount = MIN(gLSFailureCount + 1, (NSUInteger)6);
    NSUInteger shift = gLSFailureCount > 1 ? gLSFailureCount - 1 : 0;
    NSTimeInterval delay = (NSTimeInterval)(1u << MIN(shift, (NSUInteger)5));
    gLSNextRetryAt = now + delay;
    if (reason) wq_log(@"names: %@; retrying in %.0f s", reason, delay);
}

// App group containers listed in the store. This used to be a second
// full-file memmem scan on every wq_ls_container_paths() call; it now runs
// once, while the snapshot is being built from the same data.
static NSArray<NSString *> *wq_ls_container_paths_for_data(NSData *data, NSDictionary *containers)
{
    NSMutableSet<NSString *> *all = [NSMutableSet setWithArray:containers.allKeys];
    static const char needle[] = "/mobile/Containers/Shared/AppGroup/";
    const uint8_t *bytes = data.bytes, *cursor = bytes, *end = bytes + data.length;
    while (cursor < end) {
        const uint8_t *hit = memmem(cursor, (size_t)(end - cursor), needle, sizeof(needle) - 1);
        if (!hit) break;
        cursor = hit + sizeof(needle) - 1;
        if ((size_t)(end - cursor) < 36) break;
        NSString *uuid = [[NSString alloc] initWithBytes:cursor length:36 encoding:NSASCIIStringEncoding];
        if (!uuid || ![[NSUUID alloc] initWithUUIDString:uuid]) continue;
        [all addObject:[@"/private/var/mobile/Containers/Shared/AppGroup/" stringByAppendingString:uuid.uppercaseString]];
    }
    return all.allObjects;
}

static WQLSSnapshot *wq_ls_ensure_snapshot(NSString *explicitPath, BOOL force);

// Returns the current snapshot, loading it if needed. The expensive work
// (store discovery, read, parse) runs OUTSIDE wq_ls_lock(); the lock is
// only held to (a) check whether the published snapshot still matches the
// store on disk, (b) check/update the retry/miss state, and (c) publish a
// freshly parsed snapshot after re-validating its signature (double-checked
// locking). Lookups therefore never block behind a multi-second parse:
// they get the previous snapshot, or nil while the first load is in flight.
// explicitPath: a store hint (wq_ls_container_paths) — that exact file is
// parsed instead of the remembered location. force: bypass the failure
// backoff — listing containers during a scan always tries the store, while
// name lookups respect the backoff.
static WQLSSnapshot *wq_ls_ensure_snapshot(NSString *explicitPath, BOOL force)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;

    // 1. Fast path: the published snapshot still matches the store on disk.
    @synchronized (wq_ls_lock()) {
        if (gLSSnapshot) {
            BOOL samePath = !explicitPath.length || [explicitPath isEqualToString:gLSSnapshot.storePath];
            struct stat current;
            if (samePath && wq_ls_candidate_info(gLSSnapshot.storePath, &current) &&
                wq_ls_signature_equal(wq_ls_signature(&current), gLSSnapshot.signature)) {
                return gLSSnapshot;
            }
            // Stale: fall through and reload. The old snapshot stays
            // visible until the new one publishes or a failure clears it.
        } else if (!force) {
            if (now < gLSNextRetryAt) return nil;
            if (!explicitPath.length && ![defaults stringForKey:kWQLSStoreKey].length) {
                NSDate *missed = [defaults objectForKey:kWQLSMissKey];
                if ([missed isKindOfClass:NSDate.class] &&
                    now - missed.timeIntervalSinceReferenceDate < kWQLSMissRetry &&
                    now >= missed.timeIntervalSinceReferenceDate) {
                    gLSNextRetryAt = missed.timeIntervalSinceReferenceDate + kWQLSMissRetry;
                    return nil;
                }
            }
        }
    }

    // 2. Resolve the store location. No lock is held here: in test builds
    // this lists the daemon containers, which is exactly the scan a name
    // load used to wait for while holding the lock.
    BOOL hadLocation = [defaults stringForKey:kWQLSStoreKey].length > 0;
    BOOL searched = NO;
    NSString *path = nil;
    if (explicitPath.length) {
        path = explicitPath;
    } else {
        path = wq_find_ls_store(&searched);
        if (!path) {
            @synchronized (wq_ls_lock()) {
                gLSSnapshot = nil;
                if (!hadLocation && searched) {
                    // Never found, after a complete search: wait a day (or a refresh).
                    [defaults setObject:NSDate.date forKey:kWQLSMissKey];
                    gLSNextRetryAt = now + kWQLSMissRetry;
                    wq_log(@"names: LaunchServices database not found; searching again in a day or on refresh");
                } else {
                    // A known database that's briefly unreadable, or a scan that failed.
                    wq_ls_note_failure(now, @"未找到 LaunchServices 数据库");
                }
            }
            return nil;
        }
        [defaults removeObjectForKey:kWQLSMissKey];
    }

    // A failed load clears the old snapshot and records the backoff only
    // when the load was for the names path, or for the very file the old
    // snapshot came from. A bad hint for a different store must not wipe
    // the names snapshot for a good store.
    void (^fail)(NSString *) = ^(NSString *reason) {
        @synchronized (wq_ls_lock()) {
            if (!explicitPath.length ||
                (gLSSnapshot && [gLSSnapshot.storePath isEqualToString:path])) {
                gLSSnapshot = nil;
                wq_ls_note_failure(now, reason);
            }
        }
    };

    // 3. Stat, read, and parse outside the lock. Re-check under the lock
    // first: another thread may already have published this exact version.
    struct stat before;
    if (!wq_ls_candidate_info(path, &before)) {
        fail(wq_ls_error(path, @"候选项不再有效"));
        return nil;
    }
    NSDictionary *beforeSignature = wq_ls_signature(&before);
    @synchronized (wq_ls_lock()) {
        if (gLSSnapshot && [gLSSnapshot.storePath isEqualToString:path] &&
            wq_ls_signature_equal(beforeSignature, gLSSnapshot.signature)) {
            gLSFailureCount = 0;
            gLSNextRetryAt = 0;
            return gLSSnapshot;
        }
    }

    NSString *error = nil;
    NSData *data = wq_read(path, kWQLSMaxStoreBytes + 1, &error);
    if (!data || data.length > kWQLSMaxStoreBytes) {
        fail(wq_ls_error(path, error ?: @"存储超出大小限制"));
        return nil;
    }

    NSDictionary *display = nil, *bundleName = nil, *containers = nil, *bundlePaths = nil;
    if (!wq_parse_ls_store(data, &display, &bundleName, &containers, &bundlePaths)) {
        fail(wq_ls_error(path, @"存储被有界解析器拒绝"));
        return nil;
    }
    NSArray<NSString *> *containerPaths = wq_ls_container_paths_for_data(data, containers);
    WQLSSnapshot *fresh = [[WQLSSnapshot alloc] initWithDisplay:display bundleName:bundleName containers:containers
                                                     bundlePaths:bundlePaths containerPaths:containerPaths
                                                       storePath:path signature:beforeSignature];

    // 4. Publish under the lock, but only if the store still matches the
    // signature taken before the read — never publish a snapshot that was
    // changed while it was being read or parsed.
    @synchronized (wq_ls_lock()) {
        struct stat after;
        if (!wq_ls_candidate_info(path, &after) || !wq_ls_stat_equal(&before, &after)) {
            if (!explicitPath.length ||
                (gLSSnapshot && [gLSSnapshot.storePath isEqualToString:path])) {
                gLSSnapshot = nil;
                wq_ls_note_failure(now, wq_ls_error(path, @"存储在读取期间已更改"));
            }
            return nil;
        }
        if (gLSSnapshot && [gLSSnapshot.storePath isEqualToString:path] &&
            wq_ls_signature_equal(beforeSignature, gLSSnapshot.signature)) {
            gLSFailureCount = 0;
            gLSNextRetryAt = 0;
            return gLSSnapshot;
        }
        // The snapshot's dictionaries are immutable copies, assigned only
        // after a complete, validated parse. Readers therefore see either
        // the previous snapshot or this one.
        gLSSnapshot = fresh;
        gLSFailureCount = 0;
        gLSNextRetryAt = 0;
        [defaults removeObjectForKey:kWQLSMissKey];
        [defaults setObject:path forKey:kWQLSStoreKey];
        return fresh;
    }
}

// Apple's own apps and services: LaunchServices refuses this app on 27.x
// (OSStatus -54) and /Applications is not listable, so names come from here.
static NSDictionary<NSString *, NSString *> *wq_builtin_names(void)
{
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"com.apple.AppStore": @"App Store", @"com.apple.mobilesafari": @"Safari", @"com.apple.weather": @"天气",
            @"com.apple.news": @"新闻", @"com.apple.stocks": @"股市", @"com.apple.mobilemail": @"邮件",
            @"com.apple.MobileSMS": @"信息", @"com.apple.mobilephone": @"电话", @"com.apple.mobileslideshow": @"照片",
            @"com.apple.camera": @"相机", @"com.apple.mobilecal": @"日历", @"com.apple.mobilenotes": @"备忘录",
            @"com.apple.reminders": @"提醒事项", @"com.apple.Maps": @"地图", @"com.apple.Music": @"音乐",
            @"com.apple.tv": @"TV", @"com.apple.podcasts": @"播客", @"com.apple.iBooks": @"图书",
            @"com.apple.Health": @"健康", @"com.apple.Passbook": @"钱包", @"com.apple.Preferences": @"设置",
            @"com.apple.mobiletimer": @"时钟", @"com.apple.calculator": @"计算器", @"com.apple.compass": @"指南针",
            @"com.apple.VoiceMemos": @"语音备忘录", @"com.apple.facetime": @"FaceTime", @"com.apple.MobileAddressBook": @"通讯录",
            @"com.apple.DocumentsApp": @"文件", @"com.apple.findmy": @"查找", @"com.apple.Home": @"主页",
            @"com.apple.shortcuts": @"快捷指令", @"com.apple.Translate": @"翻译", @"com.apple.Fitness": @"健身",
            @"com.apple.Bridge": @"Watch", @"com.apple.freeform": @"无边记", @"com.apple.journal": @"日记",
            @"com.apple.Passwords": @"密码", @"com.apple.measure": @"测距仪", @"com.apple.Magnifier": @"放大器",
            @"com.apple.tips": @"提示", @"com.apple.siri": @"Siri", @"com.apple.games": @"游戏", @"com.apple.gamecenter": @"Game Center",
            @"com.apple.Image-Playground": @"Image Playground", @"com.apple.Photos": @"照片", @"com.apple.Keynote": @"Keynote",
            @"com.apple.Pages": @"Pages", @"com.apple.Numbers": @"Numbers", @"com.apple.mobileme.fmip1": @"查找 iPhone",
            @"com.apple.store.Jolly": @"Apple Store", @"com.apple.supportapp": @"Apple 支持", @"com.apple.Diagnostics": @"诊断",
            @"com.apple.PosterBoard": @"墙纸", @"com.apple.MercuryPoster": @"墙纸（Mercury）",
            @"com.apple.WallpaperKit.CollectionsPoster": @"墙纸精选",
            @"com.apple.PhotosUIPrivate.PhotosPosterProvider": @"照片墙纸",
            @"com.apple.chrono.WidgetRenderer-Default": @"小组件", @"com.apple.ScreenshotServicesService": @"截屏",
            @"com.apple.Sharing.AirDrop": @"隔空投送", @"com.apple.AppleMediaServicesUI": @"Apple 媒体服务",
            @"com.apple.AppleMediaServices": @"Apple 媒体服务", @"com.apple.ClarityCamera": @"辅助访问相机",
            @"com.apple.ClarityPhotos": @"辅助访问照片", @"com.apple.SystemVoiceAssistant": @"语音助手",
            @"com.apple.ShazamEventsApp": @"Shazam", @"com.apple.ScreenTimeWidgetApplication": @"屏幕使用时间",
            @"com.apple.CBRemoteSetup": @"远程设置", @"com.apple.DemoApp": @"演示", @"com.apple.AAUIViewService": @"Apple 账户",
            @"com.apple.AccountAuthenticationDialog": @"账户登录", @"com.apple.StoreKitUISceneService": @"App Store 面板",
            @"com.apple.NewDeviceOutreachApp": @"新设备设置", @"com.apple.PDUIApp": @"打印", @"com.apple.EventViewService": @"事件",
            @"com.apple.MXUIService": @"媒体选择器", @"com.apple.ctkui": @"智能卡", @"com.apple.InCallService": @"通话界面",
            @"com.apple.springboard": @"SpringBoard", @"com.apple.SafariViewService": @"Safari 视图", @"com.apple.mobilesms.compose": @"信息编写",
            @"com.apple.CompanionViewService": @"配套", @"com.apple.musicrecognition": @"音乐识别",
            @"com.apple.FontInstallViewService": @"字体安装", @"com.apple.CMViewSrvc": @"连续互通标记",
            @"com.apple.AppleCashStickerPackHost": @"Apple Cash 贴纸", @"com.apple.TVSetupUIService": @"Apple TV 设置",
            @"com.apple.HearingApp": @"听力", @"com.apple.CompanionSetup": @"配套设置",
            @"com.apple.CarPlayWallpaper": @"CarPlay 墙纸", @"com.apple.CloudKit.ShareBear": @"iCloud 共享",
            @"com.apple.EnhancedLogging": @"增强日志", @"com.apple.tcc.AuthorizationPromptService": @"隐私提示",
            @"com.apple.WebContentFilter.remoteUI.WebContentAnalysisUI": @"内容过滤",
            @"com.apple.SystemPaperViewService": @"快速备忘录", @"com.apple.HeadphoneProxService": @"耳机",
            @"com.apple.datadetectors.DDActionsService": @"数据检测器", @"com.apple.ServicesPaymentAngel": @"Apple Pay",
            @"com.apple.HomeCaptiveViewService": @"Wi-Fi 登录", @"com.apple.DiagnosticsService": @"诊断",
            @"com.apple.CarTirePressure": @"胎压", @"com.apple.FCAuthenticationUI": @"认证",
            @"com.apple.icloud.FindMyDevice.FindMyExtensionContainer": @"查找",
            @"com.apple.messages.RemoteAlerts": @"信息提醒",
            @"com.apple.AccessoryNotifications.SourceSelection": @"配件来源",
            @"com.apple.printcenter": @"打印中心", @"com.apple.BarcodeScanner": @"扫码器",
            @"com.apple.chrono.WidgetRenderer-Snapshots": @"小组件快照",
            @"com.apple.AMSEngagementViewService": @"Apple 媒体服务",
            @"com.apple.appManagedFeatures.Restrictions": @"访问限制", @"com.apple.CarRadio": @"车载收音机",
            @"com.apple.PassbookUIService": @"钱包面板", @"com.apple.Spotlight": @"聚焦搜索", @"com.apple.InputUI": @"键盘",
        };
    });
    return names;
}

// A LaunchServices display name that is not a name at all. The store's
// string table holds many kinds of strings, and on iOS 26.4 the
// display-name field of the winning layout points at one of those instead
// of the app's name: a UTI ("public.app-category.music-games"), an App
// Store category, or text that did not decode (replacement characters).
// Such a value is worse than the bundle name, so the caller falls through.
static BOOL wq_ls_display_plausible(NSString *name)
{
    if (!name.length) return NO;
    if ([name rangeOfString:@"\uFFFD"].location != NSNotFound) return NO;
    if ([name hasPrefix:@"public."]) return NO;
    if ([name rangeOfString:@".app-category"].location != NSNotFound) return NO;
    static NSCharacterSet *notIdentifierChars;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notIdentifierChars = [[NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyz0123456789.-"] invertedSet];
    });
    if (name.length > 3 &&
        [name rangeOfCharacterFromSet:notIdentifierChars].location == NSNotFound) {
        NSUInteger dots = [[name componentsSeparatedByString:@"."] count] - 1;
        if (dots >= 2) return NO;
    }
    return YES;
}

// .lproj directory names to try for a preferred language, most specific
// first. "zh-Hans-CN" -> zh-Hans-CN, zh-Hans, zh (plus underscore forms);
// "en-US" -> en-US, en. The device's preferred languages are tried in order.
static NSArray<NSString *> *wq_lproj_candidates(NSString *language)
{
    if (!language.length) return @[];
    NSArray<NSString *> *parts = [language componentsSeparatedByString:@"-"];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSInteger i = (NSInteger)parts.count; i >= 1; i--) {
        NSString *candidate = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)i)]
                               componentsJoinedByString:@"-"];
        if (![out containsObject:candidate]) [out addObject:candidate];
    }
    NSString *underscored = [language stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if (![out containsObject:underscored]) [out addObject:underscored];
    if (parts.count >= 2) {
        NSString *two = [[parts subarrayWithRange:NSMakeRange(0, 2)] componentsJoinedByString:@"_"];
        if (![out containsObject:two]) [out addObject:two];
    }
    return out;
}

// The first few bundle-name resolutions go to the Log, so a device run
// shows whether the bundle (not the LaunchServices store) supplied a name.
static void wq_bundle_display_note(NSString *bundleID, NSString *name)
{
    static NSUInteger notes;
    @synchronized (NSNull.null) {
        if (notes >= 8) return;
        notes++;
    }
    wq_log(@"names: bundle: %@ -> %@", bundleID, name);
}

// The display name from the app bundle itself. Info.plist carries
// CFBundleDisplayName (and CFBundleName as a fallback); the localized form
// lives in <language>.lproj/InfoPlist.strings under the CFBundleDisplayName
// key. This is the name SpringBoard shows, and the same file the icon
// loader already reads (with a worse_query grant when needed), so it does
// not depend on the LaunchServices record layout that iOS 26.4 broke.
// Resolved names are cached by bundle path; a reinstalled app gets a new
// path, so a stale entry is never reused. Returns nil when the bundle
// cannot be read, and the caller falls back to the store.
static NSString *wq_bundle_display_name(NSString *bundleID, WQLSSnapshot *snapshot)
{
    NSString *bundlePath = snapshot.bundlePaths[bundleID];
    if (![bundlePath isKindOfClass:NSString.class] || !bundlePath.length) return nil;
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    @synchronized (cache) {
        id hit = cache[bundlePath];
        if ([hit isKindOfClass:NSString.class]) return hit;
        if (hit == NSNull.null) return nil;
    }
    NSString *resolved = nil;
    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info && wq_grant(bundlePath)) info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if ([info isKindOfClass:NSDictionary.class]) {
        for (NSString *language in [NSLocale preferredLanguages]) {
            for (NSString *lproj in wq_lproj_candidates(language)) {
                NSString *stringsPath = [[bundlePath stringByAppendingPathComponent:
                                          [lproj stringByAppendingString:@".lproj"]]
                                         stringByAppendingPathComponent:@"InfoPlist.strings"];
                NSDictionary *strings = [NSDictionary dictionaryWithContentsOfFile:stringsPath];
                NSString *localized = [strings isKindOfClass:NSDictionary.class] ?
                    strings[@"CFBundleDisplayName"] : nil;
                if ([localized isKindOfClass:NSString.class]) {
                    resolved = wq_safe_name(localized);
                    if (resolved) break;
                }
            }
            if (resolved) break;
        }
        if (!resolved) {
            NSString *display = info[@"CFBundleDisplayName"];
            if ([display isKindOfClass:NSString.class]) resolved = wq_safe_name(display);
        }
        if (!resolved) {
            NSString *name = info[@"CFBundleName"];
            if ([name isKindOfClass:NSString.class]) resolved = wq_safe_name(name);
        }
    }
    @synchronized (cache) {
        if (cache.count > 4096) [cache removeAllObjects];
        cache[bundlePath] = resolved ?: NSNull.null;
    }
    if (resolved) wq_bundle_display_note(bundleID, resolved);
    return resolved;
}

static NSString *wq_known_name(NSString *bundleID, WQLSSnapshot *snapshot)
{
    NSString *builtin = wq_builtin_names()[bundleID];
    if (builtin) return builtin;
    NSString *display = snapshot.display[bundleID];
    if (display && wq_ls_display_plausible(display)) return display;
    return snapshot.bundleName[bundleID];
}

BOOL wq_display_names_loaded(void)
{
    @synchronized (wq_ls_lock()) { return gLSSnapshot != nil; }
}

void wq_load_display_names(void)
{
    // The parse happens outside the lock (see wq_ls_ensure_snapshot), so
    // this does not block other name lookups while the store is read.
    (void)wq_ls_ensure_snapshot(nil, NO);
}

void wq_display_names_reset_miss(void)
{
    @synchronized (wq_ls_lock()) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kWQLSMissKey];
        gLSNextRetryAt = 0;
        gLSFailureCount = 0;
    }
}

NSString *wq_bundle_id_for_container(NSString *path)
{
    if (!path.length) return nil;
    NSString *key = path.stringByStandardizingPath;
    if ([key hasPrefix:@"/var/"]) key = [@"/private" stringByAppendingString:key];
    WQLSSnapshot *snapshot = wq_ls_ensure_snapshot(nil, NO);
    NSString *bid = snapshot.containers[key];
    return [bid isKindOfClass:NSString.class] ? bid : nil;
}

NSString *wq_display_name(NSString *bundleID)
{
    if (!bundleID) return nil;
    // A label with stray whitespace (seen from a container attribute) would
    // miss every exact lookup; trim it before resolving.
    NSString *bid = [bundleID stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!bid.length) return nil;
    // One snapshot for the whole call: the store cannot change under us
    // mid-lookup, and parent fallbacks do not re-trigger a load each time.
    WQLSSnapshot *snapshot = wq_ls_ensure_snapshot(nil, NO);
    // The bundle's own localized name first: it is the name SpringBoard
    // shows, and it does not depend on the LaunchServices record layout.
    NSString *fromBundle = wq_bundle_display_name(bid, snapshot);
    if (fromBundle) return fromBundle;
    NSString *name = wq_known_name(bid, snapshot);
    if (name) return name;
    // Unknown id: use the closest parent app (com.apple.news.widget -> News).
    // The parent gets the same full resolution (bundle first), so a widget
    // of a third-party app still shows its app's name.
    NSArray *parts = [bid componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; n >= 2; n--) {
        NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
        NSString *parent = wq_display_name(prefix);
        if (parent) {
            NSString *suffix = wq_safe_name(parts.lastObject);
            return suffix.length ? [NSString stringWithFormat:@"%@ \u2013 %@", parent, suffix] : parent;
        }
    }
    return nil;
}

NSArray<NSString *> *wq_ls_container_paths(NSString *storeHint)
{
    // No lock is held here (as before): the container scan calls this while
    // a name load may be waiting for that scan. The snapshot is now shared
    // with the names path, so a store parsed here is not parsed again for
    // names, and vice versa. force=YES: listing containers during a scan
    // always tries the store, even inside the names path's failure backoff.
    // App group containers aren't mapped to an owner here; the store lists
    // the group containers of installed apps, which is what the list needs.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *path = storeHint.length ? storeHint : [defaults stringForKey:kWQLSStoreKey];
    if (!path.length) return nil;
    WQLSSnapshot *snapshot = wq_ls_ensure_snapshot(storeHint.length ? storeHint : nil, YES);
    if (!snapshot || snapshot.containers.count < 2) return nil;
    return snapshot.containerPaths;
}

NSString *wq_bundle_path_for_id(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    WQLSSnapshot *snapshot = wq_ls_ensure_snapshot(nil, NO);
    NSString *path = snapshot.bundlePaths[bundleID];
    return [path isKindOfClass:NSString.class] ? path : nil;
}
