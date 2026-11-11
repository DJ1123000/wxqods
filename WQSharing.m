//
//  WQSharing.m
//  WQ Files temporary exports and share sheets
//  GPL-3.0-or-later.
//

#import "WQSharing.h"
#import "WQUI.h"
#import "WQAccess.h"
#import <objc/runtime.h>
#import <sys/stat.h>

@interface WQSharePreparation : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIAlertController *hud;
@property (nonatomic, copy) NSString *exportDir;
@property (atomic, getter=isCancelled) BOOL cancelled;
@end

@implementation WQSharePreparation
@end

static char kWQSharePreparationKey;
static char kWQShareInFlightKey;

static NSString *wq_unique_export_directory(void)
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [@"WQShare-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    return [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:&error] ? dir : nil;
}

static void wq_remove_export(NSString *exportDir)
{
    if (exportDir.length) [NSFileManager.defaultManager removeItemAtPath:exportDir error:nil];
}

static BOOL wq_share_host_is_active(UIViewController *host)
{
    if (!host || !host.isViewLoaded || !host.view.window) return NO;
    UIWindowScene *scene = host.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return NO;
    UINavigationController *nav = host.navigationController;
    if (nav && nav.topViewController != host) return NO;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return NO;
    return YES;
}

static BOOL wq_shareable_regular_file(NSString *path)
{
    if (!path.length) return NO;
    struct stat st;
    // Do not follow a final symlink: wq_copy_to_local uses O_NOFOLLOW too.
    if (lstat(path.fileSystemRepresentation, &st) == 0) return S_ISREG(st.st_mode);
    if (wq_grant(path) && lstat(path.fileSystemRepresentation, &st) == 0) return S_ISREG(st.st_mode);
    return NO;
}

static void wq_clear_preparation(UIViewController *host, WQSharePreparation *preparation)
{
    if (!host) return;
    if (objc_getAssociatedObject(host, &kWQSharePreparationKey) == preparation) {
        objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL wq_share_in_flight(UIViewController *host)
{
    return host && (objc_getAssociatedObject(host, &kWQSharePreparationKey) ||
                    objc_getAssociatedObject(host, &kWQShareInFlightKey));
}

static void wq_clear_in_flight(UIViewController *host)
{
    if (!host) return;
    objc_setAssociatedObject(host, &kWQShareInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL wq_present_share(UIViewController *host, NSString *file, NSString *exportDir, UIView *source)
{
    if (!wq_share_host_is_active(host)) {
        wq_remove_export(exportDir);
        return NO;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:file]] applicationActivities:nil];
    UIView *anchor = source.window ? source : host.view;
    share.popoverPresentationController.sourceView = anchor;
    share.popoverPresentationController.sourceRect = anchor.bounds;
    share.completionWithItemsHandler = ^(UIActivityType __unused activityType, BOOL __unused completed,
                                         NSArray *__unused returnedItems, NSError *__unused activityError) {
        wq_remove_export(exportDir);
    };
    [host presentViewController:share animated:YES completion:^{
        // A presentation rejected after the visibility check must not strand the export.
        if (!share.presentingViewController) wq_remove_export(exportDir);
    }];
    return YES;
}

// Cancel folder preparation when its browser is popped or otherwise abandoned.
// The export is removed by the worker's completion, after any in-progress copy has stopped.
void wq_share_cancel(UIViewController *host)
{
    if (!host) return;
    wq_clear_in_flight(host);
    WQSharePreparation *preparation = objc_getAssociatedObject(host, &kWQSharePreparationKey);
    preparation.cancelled = YES;
    if (host) objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIAlertController *hud = preparation.hud;
    if (hud && host.presentedViewController == hud) {
        [host dismissViewControllerAnimated:NO completion:nil];
    }
}

// Copies a file into a unique temporary directory so concurrent shares cannot
// overwrite one another. The export is removed when the share sheet finishes.
void wq_share(UIViewController *host, NSString *path, UIView *source)
{
    if (!host) return;
    if (wq_share_in_flight(host)) {
        wq_alert(host, @"正在分享", @"请等待当前分享完成后再开始下一个。");
        return;
    }
    objc_setAssociatedObject(host, &kWQShareInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakHost = host;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *outDir = nil;
        NSString *tmp = nil;
        BOOL ok = NO;
        if (!wq_shareable_regular_file(path)) {
            error = @"只能分享常规文件。";
        } else {
            outDir = wq_unique_export_directory();
            tmp = outDir ? [outDir stringByAppendingPathComponent:path.lastPathComponent] : nil;
            ok = tmp && wq_copy_to_local(path, tmp, &error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongHost = weakHost;
            if (!ok) {
                wq_remove_export(outDir);
                wq_clear_in_flight(strongHost);
                if (wq_share_host_is_active(strongHost)) {
                    wq_alert(strongHost, @"无法分享", error ?: @"无法创建临时导出文件夹");
                }
                return;
            }
            if (!wq_share_host_is_active(strongHost) ||
                !wq_present_share(strongHost, tmp, outDir, source)) {
                wq_remove_export(outDir);
            }
            wq_clear_in_flight(strongHost);
        });
    });
}

static NSString *wq_zip_name(NSString *dir);

// Zips a folder (the system's own zipper via NSFileCoordinator) and opens the
// share sheet, so a backup can go out over AirDrop, Files, Mail…
void wq_share_folder(UIViewController *host, NSString *dir, NSString *zipName, UIView *source)
{
    if (!wq_share_host_is_active(host)) return;
    if (wq_share_in_flight(host)) {
        wq_alert(host, @"正在分享", @"请等待当前分享完成后再开始下一个。");
        return;
    }
    WQSharePreparation *preparation = [WQSharePreparation new];
    preparation.host = host;
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"正在准备…"
        message:@"正在压缩文件夹" preferredStyle:UIAlertControllerStyleAlert];
    [hud addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *__unused action) {
        preparation.cancelled = YES;
        objc_setAssociatedObject(host, &kWQSharePreparationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host dismissViewControllerAnimated:YES completion:nil];
    }]];
    preparation.hud = hud;
    objc_setAssociatedObject(host, &kWQSharePreparationKey, preparation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host presentViewController:hud animated:YES completion:nil];
    dispatch_async(wq_io(), ^{
        if (preparation.isCancelled) return;
        NSString *resolvedName = zipName ?: wq_zip_name(dir);
        NSString *safe = [[resolvedName componentsSeparatedByCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
        NSString *outDir = wq_unique_export_directory();
        preparation.exportDir = outDir;
        NSString *zip = outDir ? [outDir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"zip"]] : nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        wq_grant(dir);
        __block NSError *copyError = nil;
        NSError *coordError = nil;
        if (zip && !preparation.isCancelled) {
            // Move, don't copy: the coordinator's ZIP is a snapshot file in
            // a temporary folder, and the export folder is in the same
            // temporary area, so this is a same-volume rename — no second
            // pass over the bytes and no double disk use. A move must
            // happen inside the accessor: NSFileCoordinator unlinks its
            // snapshot once the accessor returns, so handing its URL to
            // the share sheet afterwards would point at a deleted file.
            // (Copy is kept only as a fallback if the rename ever fails.)
            [[NSFileCoordinator new] coordinateReadingItemAtURL:[NSURL fileURLWithPath:dir]
                                                        options:NSFileCoordinatorReadingForUploading
                                                          error:&coordError byAccessor:^(NSURL *zipped) {
                if (preparation.isCancelled) return;
                NSURL *destURL = [NSURL fileURLWithPath:zip];
                if (![fm moveItemAtURL:zipped toURL:destURL error:&copyError])
                    [fm copyItemAtURL:zipped toURL:destURL error:&copyError];
            }];
        }
        BOOL ok = zip && !preparation.isCancelled && [fm fileExistsAtPath:zip];
        NSString *why = (coordError ?: copyError).localizedDescription ?: @"Could not create the ZIP";
        wq_log(@"share zip: %@ -> %@ %@", dir, zip.lastPathComponent, ok ? @"OK" : why);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongHost = preparation.host;
            BOOL hudPresented = strongHost && strongHost.presentedViewController == hud;
            void (^finish)(void) = ^{
                BOOL stale = preparation.isCancelled || !wq_share_host_is_active(strongHost);
                wq_clear_preparation(strongHost, preparation);
                if (!ok || stale) {
                    wq_remove_export(outDir);
                    if (!stale && wq_share_host_is_active(strongHost)) {
                        wq_alert(strongHost, @"无法分享", why);
                    }
                    return;
                }
                if (!wq_present_share(strongHost, zip, outDir, source)) wq_remove_export(outDir);
            };
            if (hudPresented) [strongHost dismissViewControllerAnimated:YES completion:finish];
            else finish();
        });
    });
}

// "Santander 2026-11-09 14.02.11" for AppBackups/<bundle id>/<date>, else the folder name.
static NSString *wq_zip_name(NSString *dir)
{
    NSArray *parts = dir.pathComponents;
    NSUInteger i = [parts indexOfObject:@"AppBackups"];
    if (i != NSNotFound && i + 2 == parts.count - 1) {
        NSString *bid = parts[i + 1];
        return [NSString stringWithFormat:@"%@ %@", wq_display_name(bid) ?: bid, parts.lastObject];
    }
    if (i != NSNotFound && i + 1 == parts.count - 1) {
        NSString *bid = parts.lastObject;
        return [NSString stringWithFormat:@"%@ 的备份", wq_display_name(bid) ?: bid];
    }
    return dir.lastPathComponent;
}
