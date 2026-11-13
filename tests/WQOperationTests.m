//  WQOperationTests.m
//  Host regression tests for the shared operation layer (WQOperation):
//  checkpoint store round-trip and ZIP staging orphan cleanup.
//  Foundation only; runs on macOS (the iOS keep-alive is a no-op there).
//  GPL-3.0-or-later.
//

#import "../WQOperation.h"
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
    NSError *error = nil;

    // --- Checkpoint store round-trip ---
    NSString *kind = @"test-op";
    wq_operation_checkpoint_clear(kind);
    WQRequire(wq_operation_checkpoint_load(kind) == nil, @"checkpoint load returns nil when none saved");

    NSDictionary *state = @{
        @"version": @1,
        @"items": @[ @{ @"name": @"App A", @"bytes": @12345 }, @{ @"name": @"App B", @"bytes": @0 } ],
        @"measured": @[ @"/private/var/mobile/Containers/Data/Application/AAA", @"/private/var/mobile/Containers/Data/Application/BBB" ],
        @"nextIndex": @2,
        @"freed": @987654321,
        @"allOk": @YES,
    };
    wq_operation_checkpoint_save(kind, state);
    NSDictionary *loaded = wq_operation_checkpoint_load(kind);
    WQRequire(loaded != nil, @"checkpoint loads after save");
    WQRequire([loaded[@"version"] isEqual:@1], @"checkpoint version round-trips");
    WQRequire([loaded[@"items"] count] == 2, @"checkpoint items round-trip");
    WQRequire([loaded[@"items"][0][@"name"] isEqual:@"App A"], @"checkpoint item name round-trips");
    WQRequire([loaded[@"items"][0][@"bytes"] isEqual:@12345], @"checkpoint item bytes round-trip");
    WQRequire([loaded[@"measured"] count] == 2, @"checkpoint measured set round-trips");
    WQRequire([loaded[@"nextIndex"] isEqual:@2], @"checkpoint nextIndex round-trips");
    WQRequire([loaded[@"freed"] isEqual:@987654321], @"checkpoint freed round-trips");
    WQRequire([loaded[@"allOk"] boolValue], @"checkpoint allOk round-trips");

    // Overwriting replaces the stored state.
    wq_operation_checkpoint_save(kind, @{ @"version": @1, @"nextIndex": @5 });
    loaded = wq_operation_checkpoint_load(kind);
    WQRequire([loaded[@"nextIndex"] isEqual:@5], @"checkpoint overwrite replaces state");
    WQRequire(loaded[@"items"] == nil, @"checkpoint overwrite drops old keys");

    wq_operation_checkpoint_clear(kind);
    WQRequire(wq_operation_checkpoint_load(kind) == nil, @"checkpoint load returns nil after clear");
    wq_operation_checkpoint_clear(kind); // clearing a missing checkpoint is safe

    // --- ZIP staging orphan cleanup ---
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"wq-op-staging-%u", arc4random()]];
    NSString *orphanFile = [root stringByAppendingPathComponent:@".wq-zip-orphan"];
    NSString *orphanDir = [root stringByAppendingPathComponent:@".wq-unzip-orphan"];
    NSString *keepFile = [root stringByAppendingPathComponent:@"keep.txt"];
    WQRequire([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&error],
              [NSString stringWithFormat:@"create fixture dir: %@", error]);
    WQRequire([@"partial" writeToFile:orphanFile atomically:YES encoding:NSUTF8StringEncoding error:&error],
              [NSString stringWithFormat:@"create orphan staging file: %@", error]);
    WQRequire([fm createDirectoryAtPath:orphanDir withIntermediateDirectories:YES attributes:nil error:&error],
              [NSString stringWithFormat:@"create orphan staging dir: %@", error]);
    WQRequire([@"keep" writeToFile:keepFile atomically:YES encoding:NSUTF8StringEncoding error:&error],
              [NSString stringWithFormat:@"create keep file: %@", error]);

    // Nothing noted: the orphan cleanup must not touch anything.
    wq_operation_clear_zip_staging();
    wq_operation_remove_orphaned_zip_staging();
    WQRequire([fm fileExistsAtPath:orphanFile], @"orphan cleanup without a note leaves the file alone");
    WQRequire([fm fileExistsAtPath:orphanDir], @"orphan cleanup without a note leaves the dir alone");

    // Note the staging file: cleanup removes it (and the note), but not
    // the unrelated keep file.
    wq_operation_note_zip_staging(orphanFile);
    wq_operation_remove_orphaned_zip_staging();
    WQRequire(![fm fileExistsAtPath:orphanFile], @"orphan cleanup removes the noted staging file");
    WQRequire([fm fileExistsAtPath:keepFile], @"orphan cleanup leaves unrelated files alone");
    WQRequire([fm fileExistsAtPath:orphanDir], @"orphan cleanup removes only the noted staging path");

    // Note the staging dir: cleanup removes it.
    wq_operation_note_zip_staging(orphanDir);
    wq_operation_remove_orphaned_zip_staging();
    WQRequire(![fm fileExistsAtPath:orphanDir], @"orphan cleanup removes the noted staging dir");

    // Noting then clearing (a completed job) leaves nothing to clean up.
    NSString *doneFile = [root stringByAppendingPathComponent:@".wq-zip-done"];
    WQRequire([@"done" writeToFile:doneFile atomically:YES encoding:NSUTF8StringEncoding error:&error],
              [NSString stringWithFormat:@"create done staging file: %@", error]);
    wq_operation_note_zip_staging(doneFile);
    wq_operation_clear_zip_staging();
    wq_operation_remove_orphaned_zip_staging();
    WQRequire([fm fileExistsAtPath:doneFile], @"cleared staging note leaves the file alone");

    // A note pointing at a path that is already gone is not an error.
    wq_operation_note_zip_staging([root stringByAppendingPathComponent:@".wq-zip-gone"]);
    wq_operation_remove_orphaned_zip_staging();

    WQRequire([fm removeItemAtPath:root error:&error],
              [NSString stringWithFormat:@"remove fixture dir: %@", error]);

    // --- Keep-alive is a no-op on the host, but must not crash ---
    wq_operation_keep_alive_begin(@"test");
    WQRequire(!wq_operation_background_expiring(), @"background is not expiring on the host");
    wq_operation_clear_background_expiring();
    wq_operation_keep_alive_end();
    wq_operation_keep_alive_end(); // ending twice is safe

    printf("WQOperationTests: PASS\n");
    return 0;
}
