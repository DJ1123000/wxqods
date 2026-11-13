//  WQOperation.h
//  WQ Files shared layer for long operations (cache scan/clean, full scan,
//  ZIP jobs): background keep-alive + resumable checkpoints.
//
//  Why this exists: long operations used to be cancelled when the user
//  switched apps or locked the screen (the background task expired after
//  ~30 s, and leaving the page cancelled the work), and an interrupted
//  operation restarted from scratch. Now an operation is never cancelled
//  by leaving the app: the keep-alive gives it background time, the
//  worker checkpoints its progress, and a later run resumes from the
//  checkpoint instead of starting over. Only an explicit user stop cancels.
//
//  GPL-3.0-or-later.
//

#import <Foundation/Foundation.h>

// Background keep-alive shared by long operations. Only one is active at a
// time (scan and clean never run together); a new begin while one is active
// just replaces the name. On expiration iOS calls the handler, which sets
// the expiring flag (see below) and ends the task. It does NOT cancel the
// operation: the worker thread freezes with the app and continues when the
// user returns. On iOS only; a no-op elsewhere (host tests).
void wq_operation_keep_alive_begin(NSString *name);
void wq_operation_keep_alive_end(void);

// Set by the keep-alive expiration handler. A worker checks this between
// items and, when set, saves its checkpoint and clears the flag. The flag
// survives suspension (the worker sees it when the app returns), so a
// checkpoint is saved even if the worker was frozen at expiration time.
BOOL wq_operation_background_expiring(void);
void wq_operation_clear_background_expiring(void);

// Resumable checkpoints: small plists in the Caches directory, one per
// operation kind. Atomic writes; a missing or unreadable file loads as nil.
// The state must contain only plist types (NSString, NSNumber, NSArray,
// NSDictionary).
void wq_operation_checkpoint_save(NSString *kind, NSDictionary *state);
NSDictionary *wq_operation_checkpoint_load(NSString *kind);
void wq_operation_checkpoint_clear(NSString *kind);

// ZIP staging orphans. A ZIP job records its staging path when it starts
// and clears it when it finishes (success, failure or user cancel). If the
// app is terminated mid-job the staging file is left behind; the next
// launch removes it. Call the remover at launch (scene willConnect).
void wq_operation_note_zip_staging(NSString *path);
void wq_operation_clear_zip_staging(void);
void wq_operation_remove_orphaned_zip_staging(void);
