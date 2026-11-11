#import "WQAccessSafety.h"
#include <stdlib.h>

static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [NSTemporaryDirectory().stringByResolvingSymlinksInPath stringByAppendingPathComponent:
                          [@"WQAccessSafetyTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *library = [base stringByAppendingPathComponent:@"Library"];
        NSString *nested = [library stringByAppendingPathComponent:@"Caches/nested"];
        check([fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil], @"create temp fixture");
        @try {
            NSString *sentinel = [nested stringByAppendingPathComponent:@"sentinel"];
            NSData *bytes = [@"preserve these bytes" dataUsingEncoding:NSUTF8StringEncoding];
            check([bytes writeToFile:sentinel atomically:YES], @"write sentinel");
            int fd = WQOpenDirectoryNoLinks(library);
            check(fd >= 0, @"open no-link library");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin cache swap");
            check([fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"nested contents preserved while swapped");
            check(WQCacheSwapRecover(fd), @"recover simulated interruption after symlink");
            check([[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"original bytes restored");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin second swap");
            check(unlinkat(fd, "Caches", 0) == 0, @"simulate interruption before symlink");
            check(WQCacheSwapRecover(fd), @"recover absent caches");
            check([[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"bytes survive absent-path recovery");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin conflict test");
            check(unlinkat(fd, "Caches", 0) == 0 && mkdirat(fd, "Caches", 0755) == 0, @"simulate unexpected caches creator");
            check(!WQCacheSwapRecover(fd), @"recovery refuses unexpected directory");
            check([fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"conflict retains preserved original");
            check(unlinkat(fd, "Caches", AT_REMOVEDIR) == 0 && WQCacheSwapRecover(fd), @"recover after fixture conflict removed");
            check(WQCacheSwapRecover(fd), @"recovery idempotent");
            check(WQRecoverCacheSwapAtPath(library), @"normal startup requires no recovery");
            check(![fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-lock"]], @"normal startup creates no lock or marker");
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin startup recovery fixture");
            int lock = WQOpenRegularAt(fd, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
            check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, @"hold token-operation lock");
            check(!WQRecoverCacheSwapAtPath(library), @"startup does not interfere with an active token query");
            close(lock);
            check(WQRecoverCacheSwapAtPath(library) && [[NSData dataWithContentsOfFile:sentinel] isEqual:bytes], @"startup restores interrupted cache swap without a token query");
            check(WQRecoverCacheSwapAtPath([base stringByAppendingPathComponent:@"absent"]), @"startup does not create an absent Library");
            // A marker left behind by a failed write must not disable recovery
            // when the original Caches directory is intact.
            int broken = openat(fd, WQCacheMarker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            check(broken >= 0, @"create zero-length marker fixture");
            close(broken);
            check(WQCacheSwapRecover(fd), @"zero-length marker is discarded when Caches is intact");
            check(![fm fileExistsAtPath:[library stringByAppendingPathComponent:@".wq-caches-swap.plist"]], @"invalid marker removed");
            broken = openat(fd, WQCacheMarker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            check(broken >= 0 && write(broken, "partial", 7) == 7, @"create partial marker fixture");
            close(broken);
            check(WQCacheSwapRecover(fd), @"partial marker is discarded when Caches is intact");

            // A stale temporary marker must not block the next swap.
            broken = openat(fd, ".wq-caches-swap.plist.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0600);
            check(broken >= 0 && write(broken, "stale", 5) == 5, @"create stale temporary marker");
            close(broken);
            check(WQCacheSwapBegin(fd, @"/private/var/nonexistent-token-target"), @"begin cleans a stale temporary marker");
            check(WQCacheSwapRecover(fd), @"recover stale temporary marker fixture");

            // If recovery material exists, an invalid marker must fail closed.
            NSString *library2 = [base stringByAppendingPathComponent:@"Library2"];
            NSString *nested2 = [library2 stringByAppendingPathComponent:@"Caches/nested"];
            check([fm createDirectoryAtPath:nested2 withIntermediateDirectories:YES attributes:nil error:nil], @"create second library fixture");
            NSString *sentinel2 = [nested2 stringByAppendingPathComponent:@"sentinel"];
            check([bytes writeToFile:sentinel2 atomically:YES], @"write second sentinel");
            int fd2 = WQOpenDirectoryNoLinks(library2);
            check(fd2 >= 0, @"open second library");
            check(WQCacheSwapBegin(fd2, @"/private/var/nonexistent-token-target"), @"begin second swap");
            broken = openat(fd2, WQCacheMarker, O_WRONLY | O_TRUNC);
            check(broken >= 0 && write(broken, "garbage", 7) == 7, @"corrupt marker with preserved data");
            close(broken);
            check(!WQCacheSwapRecover(fd2), @"invalid marker with preserved data fails closed");
            check([fm fileExistsAtPath:[library2 stringByAppendingPathComponent:@".wq-caches-preserved/nested/sentinel"]], @"preserved data retained");
            close(fd2);

            NSString *restricted = [base stringByAppendingPathComponent:@"search-only/child"];
            check([fm createDirectoryAtPath:restricted withIntermediateDirectories:YES attributes:nil error:nil], @"create traversal fixture");
            NSString *parent = restricted.stringByDeletingLastPathComponent;
            check(chmod(parent.fileSystemRepresentation, 0111) == 0, @"set traversal-only ancestor permissions");
            @try {
                int child = WQOpenDirectoryNoLinks(restricted);
                check(child >= 0, @"no-follow walk does not require ancestor enumeration");
                close(child);
            } @finally { chmod(parent.fileSystemRepresentation, 0700); }
            check(!WQAbsolutePathGrammar(@"/private/var/../file") && !WQAbsolutePathGrammar(@"/private//var/file"), @"grammar rejects traversal and ambiguous empty components");
            close(fd);
        } @finally {
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
