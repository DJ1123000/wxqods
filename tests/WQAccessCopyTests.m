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
static void put(NSString *path, NSString *text) { check([bytes(text) writeToFile:path atomically:YES], @"write temp file"); }
static void mkdirs(NSString *path) { check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], @"create temp tree"); }
int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [WQCanonicalVarPath(NSTemporaryDirectory().stringByResolvingSymlinksInPath) stringByAppendingPathComponent:
                          [@"WQAccessCopyTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        mkdirs(base);
        @try {
            NSString *file = [base stringByAppendingPathComponent:@"source-file"];
            NSString *dest = [base stringByAppendingPathComponent:@"destination-file"];
            NSString *error = nil;
            put(file, @"source bytes");
            check(!wq_copy_to_local(file, file, &error) && has(file, @"source bytes"), @"identical-path copy preserves source");
            check(link(file.fileSystemRepresentation, dest.fileSystemRepresentation) == 0, @"create hardlink alias");
            check(!wq_copy_to_local(file, dest, &error) && has(file, @"source bytes") && has(dest, @"source bytes"), @"hardlink self-copy preserves both links");
            check(unlink(dest.fileSystemRepresentation) == 0 && symlink(file.fileSystemRepresentation, dest.fileSystemRepresentation) == 0, @"create symlink alias");
            check(!wq_copy_to_local(file, dest, &error) && has(file, @"source bytes"), @"symlink destination alias self-copy refused");
            check(!wq_copy_to_local(dest, file, &error) && has(file, @"source bytes"), @"symlink source refused safely");
            check(unlink(dest.fileSystemRepresentation) == 0, @"remove alias fixture");
            put(dest, @"old bytes");
            check(wq_copy_to_local(file, dest, &error) && has(dest, @"source bytes"), @"normal staged local copy replaces destination");
            NSString *directory = [base stringByAppendingPathComponent:@"directory"];
            mkdirs(directory); put([directory stringByAppendingPathComponent:@"sentinel"], @"directory bytes");
            check(!wq_copy_to_local(file, directory, &error) && has([directory stringByAppendingPathComponent:@"sentinel"], @"directory bytes"), @"directory destination is preserved");
            NSString *fifo = [base stringByAppendingPathComponent:@"fifo"];
            check(mkfifo(fifo.fileSystemRepresentation, 0600) == 0, @"create FIFO copy source");
            check(!wq_copy_to_local(fifo, dest, &error) && has(dest, @"source bytes"), @"special-file copy fails without blocking or removing destination");

            NSString *srcDir = [base stringByAppendingPathComponent:@"src"];
            NSString *dstDir = [base stringByAppendingPathComponent:@"dst"];
            mkdirs(srcDir); mkdirs(dstDir);
            NSString *src = [srcDir stringByAppendingPathComponent:@"child"];
            NSString *dst = [dstDir stringByAppendingPathComponent:@"child"];
            put(src, @"replacement"); put(dst, @"old destination");
            NSString *savedSource = [base stringByAppendingPathComponent:@"saved-source"];
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"copyReady"]) {
                    check(has(dst, @"old destination"), @"old destination exists before copy attempt");
                    check(rename(path.fileSystemRepresentation, savedSource.fileSystemRepresentation) == 0, @"inject copy failure by removing source");
                }
            };
            check(!wq_copy_contents(srcDir, dstDir, &error) && has(dst, @"old destination"), @"failed child copy keeps previous destination");
            wq_test_tree_hook = nil;
            check(rename(savedSource.fileSystemRepresentation, src.fileSystemRepresentation) == 0, @"restore fixture source");
            wq_test_tree_hook = ^(NSString *stage, NSString *path) {
                if ([stage isEqual:@"copyStaged"]) check(has(path, @"old destination"), @"old destination survives until completed staging");
            };
            check(wq_copy_contents(srcDir, dstDir, &error) && has(dst, @"replacement"), @"completed child atomically replaces old destination");
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:src error:nil]; [fm removeItemAtPath:dst error:nil];
            mkdirs([src stringByAppendingPathComponent:@"nested"]);
            put([src stringByAppendingPathComponent:@"nested/new"], @"new subtree");
            mkdirs([dst stringByAppendingPathComponent:@"old"]);
            put([dst stringByAppendingPathComponent:@"old/old"], @"old subtree");
            check(wq_copy_contents(srcDir, dstDir, &error) && has([dst stringByAppendingPathComponent:@"nested/new"], @"new subtree") && ![fm fileExistsAtPath:[dst stringByAppendingPathComponent:@"old"]], @"directory replacement installs complete subtree rather than merging");
            check([fm contentsOfDirectoryAtPath:dstDir error:nil].count == 1, @"successful copy removes private staging artifacts");
            check(!wq_copy_contents(srcDir, srcDir, &error), @"same-tree copy refused");
            check(!wq_copy_contents(srcDir, [srcDir stringByAppendingPathComponent:@"descendant"], &error), @"descendant copy refused before recursive staging");
            NSString *linkChild = [srcDir stringByAppendingPathComponent:@"link-child"];
            check(symlink(file.fileSystemRepresentation, linkChild.fileSystemRepresentation) == 0, @"create tree symlink child");
            check(wq_copy_contents(srcDir, dstDir, &error), @"tree copy preserves symlink item without following it");
            struct stat st;
            check(lstat([dstDir stringByAppendingPathComponent:@"link-child"].fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode), @"copied symlink remains a symlink");
        } @finally {
            wq_test_tree_hook = nil;
            [fm removeItemAtPath:base error:nil];
        }
    }
    return 0;
}
