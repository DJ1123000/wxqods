#define WQ_ACCESS_TESTING 1
#import "../WQAccess.m"
#include <stdlib.h>
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }
static void check(BOOL ok, NSString *name)
{
    if (!ok) { fprintf(stderr, "FAIL: %s (errno %d)\n", name.UTF8String, errno); exit(1); }
    printf("PASS: %s\n", name.UTF8String);
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static BOOL has(NSString *path, NSString *text) { return [[NSData dataWithContentsOfFile:path] isEqual:bytes(text)]; }
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write temp sentinel"); }
static void mkdirs(NSString *path) { check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create temp tree"); }

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQAccessTreeTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            NSString *foreign = [base stringByAppendingPathComponent:@"foreign/Caches"];
            mkdirs(foreign);
            NSString *sentinel = [foreign stringByAppendingPathComponent:@"sentinel"];
            put(sentinel, @"outside");
            NSString *container = [base stringByAppendingPathComponent:@"container"];
            mkdirs(container);
            NSString *library = [container stringByAppendingPathComponent:@"Library"];
            check(symlink(foreign.stringByDeletingLastPathComponent.fileSystemRepresentation, library.fileSystemRepresentation) == 0, @"create symlinked Library");
            unsigned long long freed = 0;
            check(!wq_purge_contents([library stringByAppendingPathComponent:@"Caches"], &freed) && has(sentinel, @"outside") && freed == 0, @"symlinked purge ancestry fails closed");
            check(!wq_purge_contents([library stringByAppendingPathComponent:@"missing"], &freed), @"unsafe ancestry not treated as missing success");
            check(!wq_purge_contents(library, &freed) && has(sentinel, @"outside"), @"symlinked final purge target refused");
            check(unlink(library.fileSystemRepresentation) == 0, @"remove fixture symlink");
            NSString *cache = [library stringByAppendingPathComponent:@"Caches"];
            mkdirs([cache stringByAppendingPathComponent:@"nested"]);
            put([cache stringByAppendingPathComponent:@"nested/file"], @"12345");
            check(symlink(foreign.fileSystemRepresentation, [cache stringByAppendingPathComponent:@"external-link"].fileSystemRepresentation) == 0, @"create child link to foreign tree");
            check(wq_purge_contents(cache, &freed) && [fm contentsOfDirectoryAtPath:cache error:nil].count == 0 && freed >= 5, @"safe purge removes nested children and leaves root");
            check(has(sentinel, @"outside"), @"purge unlinks child symlink without following it");
            NSString *alias = [cache stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
            put([cache stringByAppendingPathComponent:@"alias-file"], @"alias");
            check(wq_purge_contents(alias, &freed), @"canonical var alias accepted");
            check(wq_purge_contents([cache stringByAppendingPathComponent:@"missing"], &freed), @"safe missing folder remains success");
            put([cache stringByAppendingPathComponent:@"retained"], @"keep");
            NSString *moved = [library stringByAppendingPathComponent:@"MovedCaches"];
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"purgeChild"] && [path isEqual:cache]) {
                    check(rename(cache.fileSystemRepresentation, moved.fileSystemRepresentation) == 0, @"swap purge root after listing");
                    check(symlink(foreign.fileSystemRepresentation, cache.fileSystemRepresentation) == 0, @"install foreign purge alias");
                }
            };
            check(!wq_purge_contents(cache, &freed) && has([moved stringByAppendingPathComponent:@"retained"], @"keep") && has(sentinel, @"outside"), @"changed purge ancestry rejected before deleting listed child");
            wq_test_tree_hook = nil;

            NSString *src = [base stringByAppendingPathComponent:@"rename-source"];
            NSString *dst = [base stringByAppendingPathComponent:@"rename-destination"];
            NSString *error = nil;
            put(src, @"source");
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"renameReady"]) put(path, @"competitor");
            };
            check(!wq_rename(src, dst.lastPathComponent, &error) && has(dst, @"competitor") && has(src, @"source"), @"concurrent destination creator cannot be overwritten");
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:dst error:nil];
            check(wq_rename(src, dst.lastPathComponent, &error) && has(dst, @"source"), @"no-replace rename succeeds for absent destination");
            put(src, @"source");
            NSString *dirDest = [base stringByAppendingPathComponent:@"directory-destination"];
            mkdirs(dirDest);
            check(!wq_rename(src, dirDest.lastPathComponent, &error), @"rename preserves existing directory destination");
            NSString *linkDest = [base stringByAppendingPathComponent:@"link-destination"];
            check(symlink(sentinel.fileSystemRepresentation, linkDest.fileSystemRepresentation) == 0, @"create rename symlink destination");
            check(!wq_rename(src, linkDest.lastPathComponent, &error) && has(sentinel, @"outside"), @"rename preserves existing symlink destination");
            check(!wq_rename(src, @"..", &error) && !wq_rename(src, @".", &error), @"rename rejects special names");
            NSString *cancelDir = [base stringByAppendingPathComponent:@"cancel-cache"];
            mkdirs(cancelDir);
            NSString *cancelSentinel = [cancelDir stringByAppendingPathComponent:@"sentinel"];
            put(cancelSentinel, @"keep");
            WQScanCancellation *cancellation = [WQScanCancellation new];
            [cancellation cancel];
            freed = 0;
            check(!wq_purge_contents_cancellable(cancelDir, &freed, cancellation) && has(cancelSentinel, @"keep"),
                  @"cancelled purge leaves the tree intact");
            for (NSUInteger i = 0; i < 32; i++) {
                NSString *raceSrc = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"src-%lu", (unsigned long)i]];
                NSString *raceDst = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"dst-%lu", (unsigned long)i]];
                put(raceSrc, @"source");
                dispatch_group_t group = dispatch_group_create();
                __block BOOL created = NO;
                dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    int fd = open(raceDst.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
                    if (fd >= 0) { created = YES; check(WQWriteBytes(fd, bytes(@"competitor")), @"write racing creator"); close(fd); }
                });
                BOOL renamed = wq_rename(raceSrc, raceDst.lastPathComponent, &error);
                dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
                check(created ? (!renamed && has(raceDst, @"competitor")) : (renamed && has(raceDst, @"source")), @"race preserves whichever destination wins exclusion");
            }
        } @finally {
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
