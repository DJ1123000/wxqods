#ifndef WQ_CACHE_SAFETY_H
#define WQ_CACHE_SAFETY_H

#import <Foundation/Foundation.h>
#import <errno.h>
#import <limits.h>
#import <stdlib.h>
#import <sys/stat.h>

// Checks every existing component, including the final component when present,
// without following links. A missing final component is allowed for scan-time
// snapshots, but a missing ancestor is never accepted.
static inline BOOL WQCacheSafetyHasNoSymlinkAncestry(NSString *path, BOOL allowMissingFinal)
{
    if (!path.isAbsolutePath || !path.length) return NO;
    NSArray<NSString *> *components = path.pathComponents;
    if (components.count < 2 || ![components.firstObject isEqualToString:@"/"]) return NO;

    NSString *prefix = @"/";
    for (NSUInteger i = 1; i < components.count; i++) {
        if ([components[i] isEqualToString:@"."] || [components[i] isEqualToString:@".."]) return NO;
        prefix = [prefix stringByAppendingPathComponent:components[i]];
        struct stat st = {0};
        if (lstat(prefix.fileSystemRepresentation, &st) != 0) {
            if (allowMissingFinal && i == components.count - 1 && errno == ENOENT) return YES;
            return NO;
        }
        if (S_ISLNK(st.st_mode)) return NO;
    }
    return YES;
}

// Resolve an existing path with the filesystem's canonical spelling. For a
// missing final component, resolve its existing parent and append the final
// component without following it. realpath() is intentional here: on macOS,
// Foundation may retain /var while the filesystem's no-follow spelling is
// /private/var.
static inline NSString *WQCacheSafetyCanonicalPath(NSString *path)
{
    NSString *standard = [path stringByStandardizingPath];
    char resolved[PATH_MAX];
    if (realpath(standard.fileSystemRepresentation, resolved)) {
        return [NSString stringWithUTF8String:resolved] ?: standard;
    }

    NSString *parent = [standard stringByDeletingLastPathComponent];
    NSString *last = standard.lastPathComponent;
    if (realpath(parent.fileSystemRepresentation, resolved)) {
        NSString *resolvedParent = [NSString stringWithUTF8String:resolved];
        return [resolvedParent stringByAppendingPathComponent:last];
    }
    return standard;
}

// The lexical shape, no-follow ancestry, and canonical shape must all agree.
// `relativePath` is the expected target below the canonical container.
static inline BOOL WQCacheSafetyTargetMatchesContainer(NSString *target,
                                                         NSString *container,
                                                         NSString *relativePath)
{
    if (!relativePath.length || relativePath.isAbsolutePath) return NO;
    for (NSString *component in relativePath.pathComponents) {
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."]) return NO;
    }
    NSString *lexicalTarget = [target stringByStandardizingPath];
    NSString *lexicalExpected = [[container stringByAppendingPathComponent:relativePath]
                                 stringByStandardizingPath];
    if (![lexicalTarget isEqualToString:lexicalExpected]) return NO;
    if (!WQCacheSafetyHasNoSymlinkAncestry(target, YES)) return NO;
    if (!WQCacheSafetyHasNoSymlinkAncestry(container, NO)) return NO;

    NSString *canonicalContainer = WQCacheSafetyCanonicalPath(container);
    NSString *canonicalTarget = WQCacheSafetyCanonicalPath(target);
    NSString *canonicalExpected = [canonicalContainer stringByAppendingPathComponent:relativePath];
    return [canonicalTarget isEqualToString:canonicalExpected];
}

#endif
