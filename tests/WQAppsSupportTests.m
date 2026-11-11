#import <Foundation/Foundation.h>
#import "WQAppsSupport.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static NSDictionary *WQBaseManifest(void)
{
    return @{ @"Complete": @YES, @"Format": @1, @"BundleID": @"com.example.app",
              @"Created": [NSDate dateWithTimeIntervalSinceReferenceDate:100],
              @"Parts": @[@"Documents", @"Library"], @"Sequence": @1 };
}

static void TestManifestTypes(void)
{
    NSString *error = nil;
    NSArray *parts = nil;
    WQCheck(WQAppsSupportManifestFields(WQBaseManifest(), @"com.example.app", &parts, &error));
    BOOL canonicalParts = [parts isEqualToArray:@[@"Documents", @"Library"]];
    WQCheck(canonicalParts);

    NSMutableDictionary *wrongBundle = [WQBaseManifest() mutableCopy];
    wrongBundle[@"BundleID"] = @"com.other.app";
    WQCheck(!WQAppsSupportManifestFields(wrongBundle, @"com.example.app", NULL, &error));

    NSMutableDictionary *wrongFormat = [WQBaseManifest() mutableCopy];
    wrongFormat[@"Format"] = @2;
    WQCheck(!WQAppsSupportManifestFields(wrongFormat, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingTimestamp = [WQBaseManifest() mutableCopy];
    [missingTimestamp removeObjectForKey:@"Created"];
    WQCheck(!WQAppsSupportManifestFields(missingTimestamp, @"com.example.app", NULL, &error));

    NSMutableDictionary *duplicatePart = [WQBaseManifest() mutableCopy];
    duplicatePart[@"Parts"] = @[@"Documents", @"Documents"];
    WQCheck(!WQAppsSupportManifestFields(duplicatePart, @"com.example.app", NULL, &error));

    NSMutableDictionary *unexpectedPart = [WQBaseManifest() mutableCopy];
    unexpectedPart[@"Parts"] = @[@"Documents", @"tmp"];
    WQCheck(!WQAppsSupportManifestFields(unexpectedPart, @"com.example.app", NULL, &error));

    NSMutableDictionary *missingParts = [WQBaseManifest() mutableCopy];
    [missingParts removeObjectForKey:@"Parts"];
    WQCheck(!WQAppsSupportManifestFields(missingParts, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedReason = [WQBaseManifest() mutableCopy];
    malformedReason[@"Reason"] = @[@"not", @"text"];
    WQCheck(!WQAppsSupportManifestFields(malformedReason, @"com.example.app", NULL, &error));

    NSMutableDictionary *malformedSequence = [WQBaseManifest() mutableCopy];
    malformedSequence[@"Sequence"] = @0;
    WQCheck(!WQAppsSupportManifestFields(malformedSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *stringSequence = [WQBaseManifest() mutableCopy];
    stringSequence[@"Sequence"] = @"10";
    WQCheck(!WQAppsSupportManifestFields(stringSequence, @"com.example.app", NULL, &error));

    NSMutableDictionary *partialManifest = [WQBaseManifest() mutableCopy];
    partialManifest[@"Parts"] = @[@"Library"];
    parts = nil;
    WQCheck(WQAppsSupportManifestFields(partialManifest, @"com.example.app", &parts, &error));
    WQCheck([parts isEqualToArray:@[@"Library"]]);

    NSMutableDictionary *typedComplete = [WQBaseManifest() mutableCopy];
    typedComplete[@"Complete"] = @1;
    WQCheck(!WQAppsSupportManifestFields(typedComplete, @"com.example.app", NULL, &error));

    NSMutableDictionary *hashes = [WQBaseManifest() mutableCopy];
    hashes[@"PartHashes"] = @{ @"Documents": @"aa", @"Library": @"bb" };
    WQCheck(WQAppsSupportManifestFields(hashes, @"com.example.app", NULL, &error));
    NSMutableDictionary *missingHash = [hashes mutableCopy];
    missingHash[@"PartHashes"] = @{ @"Documents": @"aa" };
    WQCheck(!WQAppsSupportManifestFields(missingHash, @"com.example.app", NULL, &error));
    NSMutableDictionary *extraHash = [hashes mutableCopy];
    extraHash[@"PartHashes"] = @{ @"Documents": @"aa", @"Library": @"bb", @"tmp": @"cc" };
    WQCheck(!WQAppsSupportManifestFields(extraHash, @"com.example.app", NULL, &error));
    NSMutableDictionary *badHash = [hashes mutableCopy];
    badHash[@"PartHashes"] = @{ @"Documents": @1, @"Library": @"bb" };
    WQCheck(!WQAppsSupportManifestFields(badHash, @"com.example.app", NULL, &error));
}

static void TestNumericOrdering(void)
{
    NSDate *sameTime = [NSDate dateWithTimeIntervalSinceReferenceDate:100];
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00") == 1);
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00 (9)") == 9);
    WQCheck(WQAppsSupportBackupSequence(@"2026-11-09 20.00.00 (10)") == 10);
    WQCheck(WQAppsSupportCompareBackupMetadata(sameTime, 10, @"stamp (10)",
                                                sameTime, 9, @"stamp (9)") == NSOrderedDescending);
    WQCheck(WQAppsSupportCompareBackupMetadata(sameTime, 9, @"stamp (9)",
                                                sameTime, 10, @"stamp (10)") == NSOrderedAscending);
    NSDate *newer = [NSDate dateWithTimeIntervalSinceReferenceDate:101];
    WQCheck(WQAppsSupportCompareBackupMetadata(newer, 1, @"newer",
                                                sameTime, 99, @"older") == NSOrderedDescending);
}

static void TestBundleIdentifiers(void)
{
    WQCheck(WQAppsSupportBundleIDValid(@"com.example.app"));
    WQCheck(WQAppsSupportBundleIDValid(@"com.example-app_1"));
    WQCheck(!WQAppsSupportBundleIDValid(@""));
    WQCheck(!WQAppsSupportBundleIDValid(@"nodot"));
    WQCheck(!WQAppsSupportBundleIDValid(@"com/example"));
    WQCheck(!WQAppsSupportBundleIDValid(@"com..example"));
    WQCheck(!WQAppsSupportBundleIDValid(@".com.example"));
    WQCheck(!WQAppsSupportBundleIDValid(@"com.example."));
    WQCheck(!WQAppsSupportBundleIDValid(@"com example.app"));
    WQCheck(!WQAppsSupportBundleIDValid(@"../escape"));
}

static void TestJournalStates(void)
{
    WQCheck(WQAppsSupportJournalStateForDictionary(@{ @"State": @"Active" }) == WQAppsSupportJournalActive);
    WQCheck(WQAppsSupportJournalStateForDictionary(@{ @"State": @"Committed" }) == WQAppsSupportJournalCommitted);
    WQCheck(WQAppsSupportJournalStateForDictionary(@{ @"State": @"Other" }) == WQAppsSupportJournalUnknown);
    WQCheck(WQAppsSupportJournalStateForDictionary(@{}) == WQAppsSupportJournalUnknown);
    WQCheck(WQAppsSupportJournalStateForDictionary(nil) == WQAppsSupportJournalMissing);
    NSString *error = nil;
    WQCheck(!WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalActive, &error) && error.length > 0);
    error = nil;
    WQCheck(!WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalUnknown, &error) && error.length > 0);
    WQCheck(WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalMissing, NULL));
    WQCheck(WQAppsSupportJournalAllowsNewRestore(WQAppsSupportJournalCommitted, NULL));
}

static void TestTreeSignatures(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"WQAppsTree-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *src = [base stringByAppendingPathComponent:@"src"];
    NSString *dst = [base stringByAppendingPathComponent:@"dst"];
    @try {
        WQCheck([fm createDirectoryAtPath:[src stringByAppendingPathComponent:@"nested"]
              withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *file = [src stringByAppendingPathComponent:@"file"];
        WQCheck([[@"original" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
        WQCheck(symlink(file.fileSystemRepresentation,
                        [src stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);

        NSString *error = nil;
        BOOL exists = NO;
        NSString *before = WQAppsSupportTreeSignature(src, YES, &exists, &error);
        NSString *shape = WQAppsSupportTreeSignature(src, NO, &exists, &error);
        WQCheck(before.length > 0 && shape.length > 0 && exists);

        WQCheck([fm copyItemAtPath:src toPath:dst error:nil]);
        NSString *sourceAfter = WQAppsSupportTreeSignature(src, YES, &exists, &error);
        NSString *sourceShape = WQAppsSupportTreeSignature(src, NO, &exists, &error);
        NSString *destinationShape = WQAppsSupportTreeSignature(dst, NO, &exists, &error);
        WQCheck([before isEqualToString:sourceAfter]);       // source did not change
        WQCheck([sourceShape isEqualToString:destinationShape]); // copy has the same shape
        NSString *destinationIdentity = WQAppsSupportTreeSignature(dst, YES, &exists, &error);
        WQCheck(destinationIdentity && ![before isEqualToString:destinationIdentity]);

        // A source mutation after the signature was captured must be visible.
        WQCheck([[@"original plus more" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
        NSString *changed = WQAppsSupportTreeSignature(src, YES, &exists, &error);
        WQCheck(![before isEqualToString:changed]);
    } @finally {
        [fm removeItemAtPath:base error:nil];
    }
}

int main(void)
{
    @autoreleasepool {
        TestManifestTypes();
        TestNumericOrdering();
        TestBundleIdentifiers();
        TestJournalStates();
        TestTreeSignatures();
        if (failures) {
            fprintf(stderr, "%d Apps regression check(s) failed\n", failures);
            return 1;
        }
        puts("All Apps manifest/order/tree regression tests passed.");
    }
    return 0;
}
