//  WQOperation.m
//  WQ Files shared layer for long operations: background keep-alive and
//  resumable checkpoints. See WQOperation.h for the rationale.
//  GPL-3.0-or-later.
//

#import "WQOperation.h"
#import <Foundation/Foundation.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

static NSString *wq_operation_checkpoint_path(NSString *kind)
{
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir.length || !kind.length) return nil;
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"wq-op-%@.plist", kind]];
}

void wq_operation_checkpoint_save(NSString *kind, NSDictionary *state)
{
    NSString *path = wq_operation_checkpoint_path(kind);
    if (!path || !state) return;
    if (![state writeToFile:path atomically:YES]) NSLog(@"wq-op: cannot save checkpoint %@", kind);
}

NSDictionary *wq_operation_checkpoint_load(NSString *kind)
{
    NSString *path = wq_operation_checkpoint_path(kind);
    if (!path) return nil;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:path];
    return [state isKindOfClass:NSDictionary.class] ? state : nil;
}

void wq_operation_checkpoint_clear(NSString *kind)
{
    NSString *path = wq_operation_checkpoint_path(kind);
    if (path) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

static NSString *wq_operation_zip_staging_path(void)
{
    return wq_operation_checkpoint_path(@"zip-staging");
}

void wq_operation_note_zip_staging(NSString *path)
{
    NSString *note = wq_operation_zip_staging_path();
    if (!note || !path.length) return;
    if (![@{ @"path": path } writeToFile:note atomically:YES]) NSLog(@"wq-op: cannot note ZIP staging path");
}

void wq_operation_clear_zip_staging(void)
{
    NSString *note = wq_operation_zip_staging_path();
    if (note) [NSFileManager.defaultManager removeItemAtPath:note error:nil];
}

void wq_operation_remove_orphaned_zip_staging(void)
{
    NSString *note = wq_operation_zip_staging_path();
    if (!note) return;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:note];
    NSString *staging = [state[@"path"] isKindOfClass:NSString.class] ? state[@"path"] : nil;
    if (staging.length) {
        NSError *error = nil;
        if ([NSFileManager.defaultManager removeItemAtPath:staging error:&error]) {
            NSLog(@"wq-op: removed orphaned ZIP staging %@", staging);
        } else if (error.code != NSFileNoSuchFileError) {
            NSLog(@"wq-op: cannot remove orphaned ZIP staging %@: %@", staging, error);
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:note error:nil];
}

#if TARGET_OS_IOS

static UIBackgroundTaskIdentifier gKeepAliveTask = UIBackgroundTaskInvalid;
static _Atomic BOOL gBackgroundExpiring = NO;

void wq_operation_keep_alive_begin(NSString *name)
{
    if (gKeepAliveTask != UIBackgroundTaskInvalid) return;
    gKeepAliveTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:name expirationHandler:^{
        // The operation is NOT cancelled here: its worker freezes with the
        // app and continues on return. The flag only asks the worker to
        // checkpoint at its next item boundary, so a termination while
        // suspended still resumes instead of restarting.
        atomic_store_explicit(&gBackgroundExpiring, YES, memory_order_relaxed);
        if (gKeepAliveTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:gKeepAliveTask];
            gKeepAliveTask = UIBackgroundTaskInvalid;
        }
    }];
}

void wq_operation_keep_alive_end(void)
{
    if (gKeepAliveTask == UIBackgroundTaskInvalid) return;
    UIBackgroundTaskIdentifier task = gKeepAliveTask;
    gKeepAliveTask = UIBackgroundTaskInvalid;
    [UIApplication.sharedApplication endBackgroundTask:task];
}

BOOL wq_operation_background_expiring(void)
{
    return atomic_load_explicit(&gBackgroundExpiring, memory_order_relaxed);
}

void wq_operation_clear_background_expiring(void)
{
    atomic_store_explicit(&gBackgroundExpiring, NO, memory_order_relaxed);
}

#else

void wq_operation_keep_alive_begin(NSString *name) { (void)name; }
void wq_operation_keep_alive_end(void) {}
BOOL wq_operation_background_expiring(void) { return NO; }
void wq_operation_clear_background_expiring(void) {}

#endif
