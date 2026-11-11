//
//  WQPlistEditorSupportTests.m
//  WQ Files regression tests
//

#import <Foundation/Foundation.h>
#import "WQPlistEditorSupport.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void TestInputLimits(void)
{
    NSString *stringLimit = [@"" stringByPaddingToLength:WQPMaxStringInputCharacters
                                               withString:@"x"
                                          startingAtIndex:0];
    NSString *stringOver = [stringLimit stringByAppendingString:@"x"];
    NSString *dataLimit = [@"" stringByPaddingToLength:WQPMaxDataInputCharacters
                                             withString:@"0"
                                        startingAtIndex:0];
    NSString *dataOver = [dataLimit stringByAppendingString:@"0"];

    WQCheck(WQPStringInputWithinLimit(stringLimit));
    WQCheck(!WQPStringInputWithinLimit(stringOver));
    WQCheck(WQPDataInputWithinLimit(dataLimit));
    WQCheck(!WQPDataInputWithinLimit(dataOver));
}

static void TestPreviewAndSerializedLimits(void)
{
    NSString *longString = [@"" stringByPaddingToLength:WQPMaxDisplayedStringCharacters + 200
                                             withString:@"a"
                                        startingAtIndex:0];
    NSString *preview = WQPBoundedStringPreview(longString);
    WQCheck(preview.length <= WQPMaxDisplayedStringCharacters);
    WQCheck([preview containsString:@"…"]);
    WQCheck([WQPBoundedStringPreview(@"") isEqualToString:@"(empty)"]);
    WQCheck(WQPBoundedStringPreview(@"short").length == 5);

    NSData *atLimit = [NSMutableData dataWithLength:WQPMaxSerializedBytes];
    NSData *overLimit = [NSMutableData dataWithLength:WQPMaxSerializedBytes + 1];
    WQCheck(WQPSerializedDataWithinLimit(atLimit));
    WQCheck(!WQPSerializedDataWithinLimit(overLimit));
}

static void TestFormatPolicy(void)
{
    WQCheck(WQPlistFormatIsWritable(NSPropertyListXMLFormat_v1_0));
    WQCheck(WQPlistFormatIsWritable(NSPropertyListBinaryFormat_v1_0));
    WQCheck(!WQPlistFormatIsWritable(NSPropertyListOpenStepFormat));
    WQCheck([WQPlistFormatName(NSPropertyListOpenStepFormat) isEqualToString:@"OpenStep"]);
    WQCheck([WQPlistFormatName(NSPropertyListXMLFormat_v1_0) isEqualToString:@"XML"]);
    NSData *openStep = [@"{ foo = bar; }" dataUsingEncoding:NSUTF8StringEncoding];
    NSPropertyListFormat format = 0;
    id plist = [NSPropertyListSerialization propertyListWithData:openStep options:0 format:&format error:nil];
    WQCheck(plist != nil);
    WQCheck(!WQPlistFormatIsWritable(format));
}

static void TestKeyedArchiveUIDs(void)
{
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:@{ @"a": @"b" }
                                            requiringSecureCoding:NO error:nil];
    WQCheck(archive.length > 0);
    NSPropertyListFormat format = 0;
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:archive
                                                         options:NSPropertyListMutableContainersAndLeaves
                                                          format:&format error:&error];
    WQCheck([plist isKindOfClass:NSDictionary.class]);
    id uid = plist[@"$top"][@"root"];
    WQCheck(uid != nil);
    WQCheck(WQPlistIsKeyedArchiveUID(uid));
    WQCheck(!WQPlistIsKeyedArchiveUID(@"plain string"));
    WQCheck(!WQPlistIsKeyedArchiveUID(@1));

    NSString *copyError = nil;
    id copy = WQPlistImmutableCopy(plist, &copyError);
    WQCheck(copy != nil && copyError == nil);
    NSData *encoded = copy ? [NSPropertyListSerialization dataWithPropertyList:copy
                                                                        format:NSPropertyListBinaryFormat_v1_0
                                                                       options:0 error:&error] : nil;
    WQCheck(encoded.length > 0);
    if (encoded) {
        id unarchived = [NSKeyedUnarchiver unarchivedObjectOfClass:NSDictionary.class
                                                          fromData:encoded error:&error];
        WQCheck([unarchived isEqual:@{ @"a": @"b" }]);
    }

    copyError = nil;
    WQCheck(WQPlistImmutableCopy([NSNull null], &copyError) == nil && copyError.length > 0);
}

int main(void)
{
    @autoreleasepool {
        TestInputLimits();
        TestPreviewAndSerializedLimits();
        TestFormatPolicy();
        TestKeyedArchiveUIDs();
        if (failures) {
            fprintf(stderr, "%d plist support regression check(s) failed\n", failures);
            return 1;
        }
        puts("All WQPlistEditorSupport regression tests passed.");
    }
    return 0;
}
