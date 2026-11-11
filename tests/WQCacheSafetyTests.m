#import "../WQCacheSafety.h"
#import <stdio.h>
#import <stdlib.h>

static void WQRequire(BOOL condition, NSString *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [WQCacheSafetyCanonicalPath(NSTemporaryDirectory()) stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"wq-cache-safety-%u", arc4random()]];
    NSString *container = [root stringByAppendingPathComponent:@"container"];
    NSString *library = [container stringByAppendingPathComponent:@"Library"];
    NSString *caches = [library stringByAppendingPathComponent:@"Caches"];
    NSString *outside = [root stringByAppendingPathComponent:@"outside"];
    NSString *outsideCaches = [outside stringByAppendingPathComponent:@"Caches"];
    NSError *error = nil;
    WQRequire([fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:&error],
              [NSString stringWithFormat:@"create fixture: %@", error]);
    WQRequire([fm createDirectoryAtPath:outsideCaches withIntermediateDirectories:YES attributes:nil error:&error],
              [NSString stringWithFormat:@"create outside fixture: %@", error]);

    WQRequire(WQCacheSafetyHasNoSymlinkAncestry(container, NO), @"ordinary container ancestry accepted");
    WQRequire(WQCacheSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"ordinary target matches container");
    NSString *dotTarget = [container stringByAppendingPathComponent:@"Library/../Library/Caches"];
    WQRequire(!WQCacheSafetyHasNoSymlinkAncestry(dotTarget, YES), @"dot-directory traversal rejected");
    WQRequire(!WQCacheSafetyTargetMatchesContainer(dotTarget, container, @"Library/Caches"),
              @"dot-directory target rejected");

    WQRequire([fm removeItemAtPath:library error:&error], @"remove ordinary Library");
    WQRequire([fm createSymbolicLinkAtPath:library withDestinationPath:outside error:&error],
              [NSString stringWithFormat:@"create intermediate symlink: %@", error]);
    WQRequire(!WQCacheSafetyHasNoSymlinkAncestry(caches, YES), @"intermediate symlink rejected");
    WQRequire(!WQCacheSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"intermediate symlink target rejected");

    WQRequire([fm removeItemAtPath:library error:&error], @"remove intermediate symlink");
    WQRequire([fm createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:&error],
              @"restore Library");
    WQRequire([fm createSymbolicLinkAtPath:caches withDestinationPath:outsideCaches error:&error],
              [NSString stringWithFormat:@"create final symlink: %@", error]);
    WQRequire(!WQCacheSafetyHasNoSymlinkAncestry(caches, YES), @"final symlink rejected");
    WQRequire(!WQCacheSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"final symlink target rejected");

    WQRequire([fm removeItemAtPath:caches error:&error], @"remove final symlink");
    WQRequire(WQCacheSafetyHasNoSymlinkAncestry(caches, YES), @"missing final target allowed");
    WQRequire(WQCacheSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"missing final target retains expected canonical shape");

    WQRequire([fm removeItemAtPath:library error:&error], @"remove missing ancestor");
    WQRequire(!WQCacheSafetyHasNoSymlinkAncestry(caches, YES), @"missing ancestor rejected");
    WQRequire(!WQCacheSafetyTargetMatchesContainer(caches, container, @"Library/Caches"),
              @"missing ancestor target rejected");

    [fm removeItemAtPath:root error:nil];
    printf("WQCacheSafetyTests: passed\n");
    return 0;
}
