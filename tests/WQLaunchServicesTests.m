//
//  WQLaunchServicesTests.m
//  Portable LaunchServices parser/cache regression tests.
//

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "WQAccess.h"
#import "WQLaunchServices.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void Put32(NSMutableData *data, NSUInteger offset, uint32_t value)
{
    memcpy((uint8_t *)data.mutableBytes + offset, &value, sizeof(value));
}

static NSData *StoreWithName(NSString *displayName)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger nameOffset = 0x1040;
    const NSUInteger displayOffset = 0x1080;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 2u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSArray<NSString *> *values = @[@"com.example.international", @"Example", displayName];
    NSArray<NSNumber *> *offsets = @[@(idOffset), @(nameOffset), @(displayOffset)];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSData *utf8 = [values[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger offset = offsets[i].unsignedIntegerValue;
        Put32(data, offset, (uint32_t)(i + 1));
        Put32(data, offset + 4, (uint32_t)utf8.length);
        memcpy(bytes + offset + 8, utf8.bytes, utf8.length);
        bytes[offset + 8 + utf8.length] = 0;
    }
    return data;
}

static NSData *StoreWithTruncatedDisplayName(void)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger truncatedOffset = 0x1ff0;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    Put32(data, recordOffset + 8 + 0x6c, 3u << 2);
    Put32(data, recordOffset + 8 + 0x74, 3u << 2);

    NSData *bundleID = [@"com.example.international" dataUsingEncoding:NSUTF8StringEncoding];
    Put32(data, idOffset, 1u);
    Put32(data, idOffset + 4, (uint32_t)bundleID.length);
    memcpy(bytes + idOffset + 8, bundleID.bytes, bundleID.length);
    bytes[idOffset + 8 + bundleID.length] = 0;

    const char *truncated = "Truncate";
    Put32(data, truncatedOffset, 3u);
    Put32(data, truncatedOffset + 4, 8u);
    memcpy(bytes + truncatedOffset + 8, truncated, 8);
    return data;
}

static NSString *TemporaryStorePath(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"WQLaunchServicesTests-%d.csstore", getpid()]];
}

static void WriteData(NSData *data, NSString *path)
{
    NSError *error = nil;
    WQCheck([data writeToFile:path options:NSDataWritingAtomic error:&error]);
    WQCheck(!error);
}

static void TestRetryAfterDiscoveryFailure(NSString *path)
{
    NSMutableData *invalid = [NSMutableData dataWithLength:0x0fff];
    memcpy(invalid.mutableBytes, "bdsl", 4);
    WriteData(invalid, path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck(wq_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Retry 日本"), path);
    sleep(2); // The bounded retry backoff starts at one second.
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Retry 日本"]);
}

static void TestRefreshAndUnicodeSafety(NSString *path)
{
    WriteData(StoreWithName(@"Cafe\u0301 日本 \u202Eevil"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Café 日本 �evil"]);

    WriteData(StoreWithTruncatedDisplayName(), path);
    WQCheck(wq_display_name(@"com.example.international") == nil);

    WriteData(StoreWithName(@"Fresh name"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Fresh name"]);
}

static void PutString(NSMutableData *data, NSUInteger offset, uint32_t sid, NSString *value)
{
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    Put32(data, offset, sid);
    Put32(data, offset + 4, (uint32_t)utf8.length);
    memcpy((uint8_t *)data.mutableBytes + offset + 8, utf8.bytes, utf8.length);
    // No terminator when the length is a multiple of 4, like the real store;
    // fill the next word so a missing-terminator bug would read garbage.
    if (utf8.length % 4 == 0) ((uint8_t *)data.mutableBytes)[offset + 8 + utf8.length] = 0x30;
    else ((uint8_t *)data.mutableBytes)[offset + 8 + utf8.length] = 0;
}

static NSString *const kAppPath = @"/private/var/mobile/Containers/Data/Application/4CE791DB-6B04-4A39-8F59-AF32BA61D494";
static NSString *const kPluginPath = @"/private/var/mobile/Containers/Data/PluginKitPlugin/42D859EB-1323-451C-88F6-01AEE4F45958";
static NSString *const kSharedPath = @"/private/var/mobile/Containers/Data/PluginKitPlugin/051B043F-07C6-4AB6-9B43-F70BFA8B1A81";

// Bundle record: +0x0c id, +0x68 container path, +0x6c name, +0x74 display
// name. Plugin records (0x118 bytes): +0x00 id, +0x54 container path.
static NSData *StoreWithContainers(void)
{
    NSMutableData *data = [NSMutableData dataWithLength:0x3000];
    memcpy(data.mutableBytes, "bdsl", 4);
    const NSUInteger bundle = 0x200, plugin = 0x500, other = 0x700, third = 0x900;
    Put32(data, bundle + 4, 0x250);
    Put32(data, bundle + 8 + 0x0c, 1u << 2);
    Put32(data, bundle + 8 + 0x68, 2u << 2);
    Put32(data, bundle + 8 + 0x6c, 3u << 2);
    Put32(data, bundle + 8 + 0x74, 3u << 2);
    Put32(data, plugin + 4, 0x118);
    Put32(data, plugin + 8 + 0x00, 4u << 2);
    Put32(data, plugin + 8 + 0x54, 5u << 2);
    // Two extensions claiming the same container: neither is trusted.
    Put32(data, other + 4, 0x118);
    Put32(data, other + 8 + 0x00, 4u << 2);
    Put32(data, other + 8 + 0x54, 6u << 2);
    Put32(data, third + 4, 0x118);
    Put32(data, third + 8 + 0x00, 7u << 2);
    Put32(data, third + 8 + 0x54, 6u << 2);
    PutString(data, 0x1000, 1, @"com.example.app");
    PutString(data, 0x1080, 2, kAppPath);                       // 84 bytes
    PutString(data, 0x1100, 3, @"AppName8");                    // 8 bytes
    PutString(data, 0x1180, 4, @"com.example.app.widget");
    PutString(data, 0x1200, 5, kPluginPath);                    // 88 bytes
    PutString(data, 0x1280, 6, kSharedPath);
    PutString(data, 0x1300, 7, @"com.example.other");
    return data;
}

static void TestContainerMapping(NSString *path)
{
    WriteData(StoreWithContainers(), path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck([wq_bundle_id_for_container(kAppPath) isEqualToString:@"com.example.app"]);
    WQCheck([wq_bundle_id_for_container([kAppPath substringFromIndex:8]) isEqualToString:@"com.example.app"]);  // /var/...
    WQCheck([wq_bundle_id_for_container(kPluginPath) isEqualToString:@"com.example.app.widget"]);
    WQCheck(wq_bundle_id_for_container(kSharedPath) == nil);
    WQCheck(wq_bundle_id_for_container(@"/private/var/mobile/Containers/Data/Application/not-a-uuid") == nil);
    // A display name whose length is a multiple of 4 has no terminator.
    WQCheck([wq_display_name(@"com.example.app") isEqualToString:@"AppName8"]);
}

// A store whose display name is displayName but whose bundle-name field is
// absent (ref 0), so the bundle name is unknown: the plausibility check
// must still reject a descriptive display name using the bundle id alone.
static NSData *StoreWithNameNoBundleName(NSString *displayName)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000;
    const NSUInteger displayOffset = 0x1080;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);
    // Name field at +0x6c intentionally left 0 (no bundle name).
    Put32(data, recordOffset + 8 + 0x74, 2u << 2);

    NSArray<NSString *> *values = @[@"com.example.international", displayName];
    NSArray<NSNumber *> *offsets = @[@(idOffset), @(displayOffset)];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSData *utf8 = [values[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger offset = offsets[i].unsignedIntegerValue;
        Put32(data, offset, (uint32_t)(i + 1));
        Put32(data, offset + 4, (uint32_t)utf8.length);
        memcpy(bytes + offset + 8, utf8.bytes, utf8.length);
        bytes[offset + 8 + utf8.length] = 0;
    }
    return data;
}

// A 0xe8-byte bundle record (the iOS 26.4.1 layout): bundle id at +0x0c,
// container at +0x60, bundle name at +0x64, display name at +0x6c,
// bundle path at +0x00.
static NSData *StoreWith26_4Record(NSString *bundleID, NSString *bundleName, NSString *displayName)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000, containerOffset = 0x1100, nameOffset = 0x1040;
    const NSUInteger displayOffset = 0x1080, pathOffset = 0x1180;
    NSMutableData *data = [NSMutableData dataWithLength:0x2000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x0e8);
    Put32(data, recordOffset + 8 + 0x00, 6u << 2);   // bundle path
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);   // bundle id
    Put32(data, recordOffset + 8 + 0x60, 2u << 2);   // container path
    Put32(data, recordOffset + 8 + 0x64, 3u << 2);   // bundle name
    Put32(data, recordOffset + 8 + 0x6c, 4u << 2);   // display name
    PutString(data, idOffset, 1, bundleID);
    PutString(data, containerOffset, 2, kAppPath);
    PutString(data, nameOffset, 3, bundleName);
    PutString(data, displayOffset, 4, displayName);
    PutString(data, pathOffset, 6, @"/private/var/containers/Bundle/Application/4CE791DB-6B04-4A39-8F59-AF32BA61D494/Example.app");
    return data;
}

static void TestDisplayNamePlausibility(NSString *path)
{
    // A UTI / App Store category is not an app name: fall back to the bundle name.
    WriteData(StoreWithName(@"public.app-category.music-games"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    // A bare reverse-DNS identifier is not an app name either.
    WriteData(StoreWithName(@"com.example.something"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    // Text that did not decode (replacement character) is not a name.
    WriteData(StoreWithName(@"Bad\uFFFDEvil"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    // A normal localized name still wins over the bundle name.
    WriteData(StoreWithName(@"Retry \u65e5\u672c"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Retry \u65e5\u672c"]);
    // Wrong-language / descriptive garbage from the iOS 26.4 store falls back
    // to the bundle name instead of being shown.
    WriteData(StoreWithName(@"Kod sumber Fortran"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    WriteData(StoreWithName(@"preprocessed C source code"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    WriteData(StoreWithName(@"iOS-simulaattori"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    WriteData(StoreWithName(@"Macmini3,1"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    WriteData(StoreWithName(@"מגדל"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    WriteData(StoreWithName(@"Симуляторы"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    WriteData(StoreWithName(@"रेसिंग गेम"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example"]);
    // A multi-word name that shares a word with the bundle name is real.
    WriteData(StoreWithName(@"Example App Pro"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"Example App Pro"]);
    // A two-word name is a plausible app name even without a shared word.
    WriteData(StoreWithName(@"App Store"), path);
    WQCheck([wq_display_name(@"com.example.international") isEqualToString:@"App Store"]);
    // A descriptive display name is still rejected when the bundle name is
    // unknown (no bundle-name field in the store): the bundle id alone
    // must not let it through. The name falls back to nothing here (the
    // caller shows the bundle id), never to the garbage string.
    WriteData(StoreWithNameNoBundleName(@"Kod sumber Fortran"), path);
    WQCheck(wq_display_name(@"com.example.international") == nil);
    WriteData(StoreWithNameNoBundleName(@"preprocessed C source code"), path);
    WQCheck(wq_display_name(@"com.example.international") == nil);
}

static NSString *WriteTestBundle(NSString *displayName, NSString *localizedName)
{
    // A fresh path per bundle: wq_bundle_display_name caches by bundle path
    // (on device a reinstall gets a new path), so reusing one path for
    // different content would return the stale cached name.
    static NSUInteger bundleCounter;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"WQBundleTest-%d-%lu.app", getpid(),
                      (unsigned long)bundleCounter++]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *plist = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\"><dict>"
        @"<key>CFBundleDisplayName</key><string>%@</string>"
        @"<key>CFBundleName</key><string>PlistApp</string>"
        @"</dict></plist>", displayName];
    [plist writeToFile:[dir stringByAppendingPathComponent:@"Info.plist"]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (localizedName) {
        NSString *firstLang = [NSLocale preferredLanguages].firstObject ?: @"en";
        NSString *lproj = [dir stringByAppendingPathComponent:[firstLang stringByAppendingString:@".lproj"]];
        [fm createDirectoryAtPath:lproj withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *strings = [NSString stringWithFormat:@"\"CFBundleDisplayName\" = \"%@\";\n", localizedName];
        [strings writeToFile:[lproj stringByAppendingPathComponent:@"InfoPlist.strings"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    return dir;
}

// One bundle record (27.0 layout) whose bundle path is bundlePath and whose
// store display name is displayName (a UTI-like string, so the bundle must win).
static NSData *StoreWithBundlePath(NSString *bundlePath, NSString *displayName)
{
    const NSUInteger recordOffset = 0x200;
    const NSUInteger idOffset = 0x1000, containerOffset = 0x1100, nameOffset = 0x1040;
    const NSUInteger displayOffset = 0x1080, pathOffset = 0x1180;
    NSMutableData *data = [NSMutableData dataWithLength:0x3000];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "bdsl", 4);
    Put32(data, recordOffset + 4, 0x250);
    Put32(data, recordOffset + 8 + 0x00, 6u << 2);   // bundle path
    Put32(data, recordOffset + 8 + 0x0c, 1u << 2);   // bundle id
    Put32(data, recordOffset + 8 + 0x68, 2u << 2);   // container path
    Put32(data, recordOffset + 8 + 0x6c, 3u << 2);   // bundle name
    Put32(data, recordOffset + 8 + 0x74, 4u << 2);   // display name
    PutString(data, idOffset, 1, @"com.example.plistapp");
    PutString(data, containerOffset, 2, kAppPath);
    PutString(data, nameOffset, 3, @"PlistApp");
    PutString(data, displayOffset, 4, displayName);
    PutString(data, pathOffset, 6, bundlePath);
    return data;
}

static void TestBundleDisplayName(NSString *path)
{
    // Base Info.plist name wins over a UTI-like store display name.
    NSString *bundle = WriteTestBundle(@"Plist App", nil);
    WriteData(StoreWithBundlePath(bundle, @"public.app-category.music-games"), path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    WQCheck([wq_display_name(@"com.example.plistapp") isEqualToString:@"Plist App"]);
    [[NSFileManager defaultManager] removeItemAtPath:bundle error:nil];

    // Localized InfoPlist.strings wins over the base Info.plist name.
    bundle = WriteTestBundle(@"Base App", @"Plist App Localized");
    WriteData(StoreWithBundlePath(bundle, @"public.app-category.music-games"), path);
    WQCheck([wq_display_name(@"com.example.plistapp") isEqualToString:@"Plist App Localized"]);
    [[NSFileManager defaultManager] removeItemAtPath:bundle error:nil];
}

static void Test26_4Layout(NSString *path)
{
    // A 0xe8-byte record resolves through the 26.4 layout: the container
    // maps, and the name comes from its display-name field.
    WriteData(StoreWith26_4Record(@"com.example.eight", @"WeChat", @"微信"), path);
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"WQLaunchServicesStore"];
    // A Chinese display name wins (Chinese first).
    WQCheck([wq_display_name(@"com.example.eight") isEqualToString:@"微信"]);
    WQCheck([wq_bundle_id_for_container(kAppPath) isEqualToString:@"com.example.eight"]);
    // A garbage display name in a 0xe8 record falls back to the English
    // bundle name, never the garbage.
    WriteData(StoreWith26_4Record(@"com.example.eight", @"WeChat", @"Kod sumber Fortran"), path);
    WQCheck([wq_display_name(@"com.example.eight") isEqualToString:@"WeChat"]);
    // A plausible English display name still wins.
    WriteData(StoreWith26_4Record(@"com.example.eight", @"WeChat", @"WeChat"), path);
    WQCheck([wq_display_name(@"com.example.eight") isEqualToString:@"WeChat"]);
}

static void TestOversizedStoreFailsClosed(NSString *path)
{
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    WQCheck(fd >= 0);
    if (fd < 0) return;
    off_t size = (off_t)(64u * 1024u * 1024u + 1u);
    WQCheck(ftruncate(fd, size) == 0);
    WQCheck(write(fd, "bdsl", 4) == 4);
    close(fd);
    WQCheck(wq_display_name(@"com.example.international") == nil);
}

int main(void)
{
    @autoreleasepool {
        NSString *path = TemporaryStorePath();
        id oldPreference = [NSUserDefaults.standardUserDefaults objectForKey:@"WQLaunchServicesStore"];
        @try {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
            TestRetryAfterDiscoveryFailure(path);
            TestRefreshAndUnicodeSafety(path);
            TestContainerMapping(path);
            TestDisplayNamePlausibility(path);
            TestBundleDisplayName(path);
            Test26_4Layout(path);
            TestOversizedStoreFailsClosed(path);
        } @finally {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            if (oldPreference) [NSUserDefaults.standardUserDefaults setObject:oldPreference forKey:@"WQLaunchServicesStore"];
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WQLaunchServicesStore"];
        }
        if (failures) {
            fprintf(stderr, "%d LaunchServices regression check(s) failed\n", failures);
            return 1;
        }
        puts("All LaunchServices regression tests passed.");
    }
    return 0;
}

#pragma mark - Portable WQAccess test doubles

void wq_log(NSString *__unused format, ...)
{
}

BOOL wq_stat(NSString *path, struct stat *st)
{
    return lstat(path.fileSystemRepresentation, st) == 0;
}

NSData *wq_read(NSString *path, NSUInteger maxBytes, NSString **errorText)
{
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!data) {
        if (errorText) *errorText = error.localizedDescription ?: @"read failed";
        return nil;
    }
    if (maxBytes && data.length > maxBytes) return [data subdataWithRange:NSMakeRange(0, maxBytes)];
    return data;
}

NSArray<NSString *> *wq_enumerate(NSString *__unused dir, int64_t __unused maxInode,
                                   WQScanCancellation *__unused cancellation,
                                   void (^__unused progress)(int64_t, int64_t, NSUInteger))
{
    return nil;
}

BOOL wq_system_areas_reachable(void)
{
    return YES;   // the fixtures model iOS 27, where the daemon containers are listed
}

NSArray<NSString *> *wq_list(NSString *__unused dir, NSString *__unused *errorText)
{
    return nil;
}

// The bundle-name resolver grants the bundle path when a direct read fails;
// fixtures are in a readable temp dir, so the grant is never needed here.
BOOL wq_grant(NSString *__unused path)
{
    return NO;
}
