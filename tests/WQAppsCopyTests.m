// Compile the real copy implementation against a temporary tree and verify the
// same source-stability plus destination-shape checks used by app backups.
#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#import "WQAppsSupport.h"
#include <stdlib.h>

SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void Put(NSString *path, NSString *text)
{
    WQCheck([[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath)
                          stringByAppendingPathComponent:
                          [@"WQAppsCopyTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *src = [base stringByAppendingPathComponent:@"src"];
        NSString *dst = [base stringByAppendingPathComponent:@"dst"];
        @try {
            WQCheck([fm createDirectoryAtPath:[src stringByAppendingPathComponent:@"nested"]
                  withIntermediateDirectories:YES attributes:nil error:nil]);
            Put([src stringByAppendingPathComponent:@"file"], @"original bytes");
            Put([src stringByAppendingPathComponent:@"nested/child"], @"nested bytes");
            WQCheck(symlink([src stringByAppendingPathComponent:@"file"].fileSystemRepresentation,
                            [src stringByAppendingPathComponent:@"link"].fileSystemRepresentation) == 0);

            NSString *error = nil;
            BOOL exists = NO;
            NSString *sourceBefore = WQAppsSupportTreeSignature(src, YES, &exists, &error);
            WQCheck(sourceBefore.length > 0 && exists);
            WQCheck(wq_copy_contents(src, dst, &error));
            NSString *sourceAfter = WQAppsSupportTreeSignature(src, YES, &exists, &error);
            NSString *sourceShape = WQAppsSupportTreeSignature(src, NO, &exists, &error);
            NSString *destinationShape = WQAppsSupportTreeSignature(dst, NO, &exists, &error);
            WQCheck(sourceAfter && sourceShape && destinationShape);
            WQCheck([sourceBefore isEqualToString:sourceAfter]);
            WQCheck([sourceShape isEqualToString:destinationShape]);

            // The empty-tree case is also a valid copy.
            NSString *emptySrc = [base stringByAppendingPathComponent:@"empty-src"];
            NSString *emptyDst = [base stringByAppendingPathComponent:@"empty-dst"];
            WQCheck([fm createDirectoryAtPath:emptySrc withIntermediateDirectories:YES attributes:nil error:nil]);
            WQCheck(wq_copy_contents(emptySrc, emptyDst, &error));
            NSString *emptyShape = WQAppsSupportTreeSignature(emptyDst, NO, &exists, &error);
            WQCheck(emptyShape && ![emptyShape isEqualToString:@"<missing>"] && exists);

            // Mutating the source after the copy changes the source shape.
            Put([src stringByAppendingPathComponent:@"file"], @"different bytes!");
            NSString *changedShape = WQAppsSupportTreeSignature(src, NO, &exists, &error);
            WQCheck(![changedShape isEqualToString:destinationShape]);

            // Content hashing detects a same-size byte change that the shape hash cannot.
            NSString *contentBefore = WQAppsSupportTreeContentSignature(dst, &exists, &error);
            WQCheck(contentBefore && exists);
            Put([dst stringByAppendingPathComponent:@"file"], @"ORIGINAL BYTES");
            NSString *contentAfter = WQAppsSupportTreeContentSignature(dst, &exists, &error);
            WQCheck(contentAfter && ![contentAfter isEqualToString:contentBefore]);

            // A copy failure must not leave a published destination.
            NSString *missing = [base stringByAppendingPathComponent:@"missing"];
            WQCheck(!wq_copy_contents(missing, [base stringByAppendingPathComponent:@"never"], &error));
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
        if (failures) {
            fprintf(stderr, "%d app copy regression check(s) failed\n", failures);
            return 1;
        }
        puts("All Apps copy regression tests passed.");
    }
    return 0;
}
