# Cache scan/clean interrupted by switching apps + clear-log button

## 1. Cache scan/clean interrupted by switching apps

### What the user saw

During a cache scan (or clean), switching to another app interrupted the
operation. Coming back forced a full rescan, and the rescan then failed:
the screen showed "可回收 0 KB" with the note "扫描不完整：1 个容器枚举失败；
已排除受限的行；其余行仍可清理。见日志。" and the 选择/清理 buttons greyed
out — no way forward except killing the app.

### Root cause (as understood from code)

Three separate problems combined:

1. **No background task.** The whole-device full scan (`main.m`,
   `gScanBackgroundTask`, `beginBackgroundTaskWithName:@"WQ full scan"`)
   is protected when the user switches away. The cache scan and clean in
   `WQCache.m` had **no** background task, so iOS suspended the process
   within seconds of switching apps and the in-flight scan froze
   mid-flight. Backgrounding does *not* call `viewWillDisappear` (that
   only fires for in-app navigation), so the freeze was purely the
   suspension, not a cancel. On return the app either resumed a stale
   scan or — if iOS had reclaimed it (jetsam) — relaunched and started a
   full rescan from `viewDidLoad`.
2. **A cancelled/interrupted scan discarded everything.** Every
   cancellation exit in the scan (`if (cancellation.isCancelled) return;`
   at the root loop, the container loop, the measurement, and the crash-log
   step) returned from the background block without publishing. The items
   measured so far were thrown away, and `_items` kept whatever it had —
   on a first scan, nothing — so the screen showed 0 KB.
3. **A failed rescan wiped a good list.** When a root enumeration
   returned nil, the scan still ran to completion and published its
   (empty) items, overwriting the previous good list. One failed root
   plus the 64 KB skip (`cacheBytes + tempBytes < 64 * 1024` → no item)
   left `_items` empty, hence 0 KB and greyed-out buttons
   (`clean.enabled = n > 0`, `select.enabled = visible.count > 0`).

   The single failed root ("1 个容器枚举失败") itself: the two roots
   (Application, PluginKitPlugin) are enumerated through one shared scan
   (`wq_shared_children` / `wq_run_shared_scan`), which returns all roots
   together or nil — so a lone failure most likely comes from a per-root
   pre-check (`lstat`/`statfs`) failing transiently after a suspend/resume
   (a dropped container-manager / LaunchServices IPC, or a stale sandbox
   grant), or from the two `wq_enumerate` calls straddling a slot
   invalidation. I could **not** prove which root or which call from
   static analysis alone; the device log lines (`cache scan: … container
   enumeration failed` and the `scan: …` lines from `wq_run_shared_scan`)
   will say. The fix below retries the enumeration once and, crucially,
   no longer lets one failed root zero out the list.

### What I changed (`WQCache.m`)

- **Background task for scan and clean** — new file-static helpers
  `WQCacheBeginBackgroundTask` / `WQCacheEndBackgroundTask` (one shared
  task id; scan and clean never run at the same time). `scan` begins
  `@"WQ cache scan"`, `clean` begins `@"WQ cache clean"`. The task is
  ended in every completion path (scan publish, clean validation-failure,
  clean main completion). On expiration the handler cancels the current
  scan/clean cancellation on the main queue, so the work stops cleanly
  and publishes partial results instead of being lost. iOS grants ~30 s;
  a scan that takes minutes will still be suspended after that, but the
  interruption is now handled instead of fatal.
- **Interrupted scans publish partial results.** The scan block now uses
  an `interrupted` flag instead of bare `return` on cancellation: every
  cancel point sets it and breaks out, and the scan always reaches the
  publish step. The completion only returns early if a *newer* scan owns
  the screen (generation changed); a cancelled scan with the current
  generation publishes the items it found, with the note prefixed by
  "扫描被中断". Crash logs are skipped when interrupted.
- **One retry per root enumeration.** If `wq_enumerate` returns nil for a
  root (and the scan was not cancelled), the scan logs
  `cache scan: … container enumeration failed; retrying once`,
  re-establishes access with `wq_grant(root)`, and tries once more
  before counting the root as failed.
- **A failed rescan keeps the previous list.** In the publish step, if
  the new scan found zero items *and* a root enumeration failed *and* a
  previous list exists, the previous `_items` is kept (not overwritten
  with an empty list), so the user can still clean from the last good
  scan and is not left with 0 KB and greyed-out buttons. The
  "扫描不完整" note still shows. Pull-to-refresh still forces a fresh
  scan.

`viewWillDisappear` still cancels a scan/clean when the user navigates
away *inside* the app — that is intentional (don't churn while hidden) —
but the cancel now publishes partial results, so coming back shows what
was found instead of an empty screen.

### What I could NOT verify (no Mac / no device here)

- Not compiled: no Xcode on this Linux VM. Bracket balance and
  format-string consistency checked by hand/grep only; the real build
  must run on GitHub Actions as before.
- Whether the ~30 s background task is enough for the enumeration phase
  to finish (it usually is — enumeration is the fast part; measuring
  300+ containers is the slow part). If the scan is still suspended
  mid-measurement, the partial-results path is what saves it.
- The exact single-root failure mechanism (see above) — the retry and
  the keep-previous-list fix cover it regardless, but the log lines will
  confirm which root/call failed.
- No existing tests cover the cache scan/clean flow (only
  `tests/WQCacheSafetyTests.m` for the safety helpers), so no test was
  added or changed. The scan/clean behaviour change is covered by the
  on-device checks below.

### What to check on-device after installing

1. Start a cache scan, switch to another app for about a minute, come
   back: the scan should either have finished in the background or
   resume/complete, and the list should show the apps with their sizes —
   **not** "可回收 0 KB" with greyed-out buttons.
2. Same for a clean: start cleaning, switch away, come back — it should
   report what was freed (or stop cleanly after the current item), not
   vanish.
3. If a rescan ever still reports "1 个容器枚举失败", check that the
   previous list is still shown and cleanable (not 0 KB), and send the
   log lines starting with `cache scan:` and `scan:` — they say which
   root failed and whether the retry ran.

## 2. Clear-log button (Log screen)

- Added `wq_log_clear()` (`WQAccess.h` / `WQAccess.m`): locks with the
  same `gLogLock` as `wq_log` / `wq_log_text` and empties the in-memory
  `gLog` buffer. Nil-safe before the first log line.
- Log screen (`WQLogViewController` in `main.m`): the navigation bar now
  has **two** right buttons — "清空" (Clear, text button) on the left and
  Share (system action icon) on the right, where Share was. Tapping
  清空 asks "确定要清空日志吗？" (取消 / 清空); on 清空 it calls
  `wq_log_clear()` and refreshes the text view. The version/device header
  is not part of `gLog`, so after clearing the view still shows the
  header; when the log body is empty `fullLog` now shows "（日志为空）"
  instead of a bare blank, so the empty state reads sensibly. Share
  still shares the same `fullLog` (header + body, or the placeholder
  when empty).

---

# Follow-up: CN3 cache scan finds only 6 items (regression, 2026-11-11)

## What the user saw

On CN2 the cache scan found 210 items / 20.25 GB. On CN3 it found
only 6 items / 2.8 MB, all tiny (900 KB, 506 KB, 469 KB, 409 KB,
401 KB, 131 KB), all selected. The multi-GB items (WeChat 1.16 GB
cache, QQ 1.14 GB, etc.) were gone entirely — not shown as limited or
unselected, just absent. The user did not clean successfully in
between, so the cache was still there; the scan itself was missing
almost everything.

## What was ruled out (code + device log)

- **Enumeration is healthy.** The device log shows the app scan
  enumerating 314 containers / 313 apps measured, and the shared scan
  is slot-cached, so `wq_enumerate` returns the full list. The log
  also confirms the LS store parse works. The regression is in the
  cache scan's own measurement/publish path, not in enumeration.
- **Measurement is honest.** `wq_measure_tree_impl` returns real byte
  counts; a container it cannot read returns `Limited`, and a limited
  container is still listed (as a limited row), not dropped. The
  `< 64 KB` skip only applies when both Caches and tmp are *Known*
  and sum to < 64 KB, so it cannot drop a GB-sized cache. The size
  cache shared with the Apps screen stores real per-bucket subtotals
  (both screens use `wq_measure_tree_subtotals`), so a warm cache
  cannot zero out a big item either.
- **The "keep previous list" logic cannot stick a small list.** It
  only fires when the new scan found 0 items *and* a root enumeration
  failed *and* a previous list exists; a scan that found 6 items
  replaces the list with those 6. So the 6 items are this scan's own
  (partial) result.

## Root cause

The 6 items are a **partial result from a scan interrupted
mid-measurement, which was then never completed**. The CN3 restructure
made interrupted scans publish partial results (correct), but nothing
retried them:

1. The user was testing the background-switch fix, so the scan was
   interrupted — by the background-task expiration (iOS grants ~30 s;
   the handler cancels the scan) and/or by `viewWillDisappear` when
   navigating away in-app. The scan broke out of the container loop
   after measuring only the first few containers and published them
   (6 items, all small because they are the first in enumeration
   order, not the largest).
2. After publishing, `_scanning = NO` and `_lastScanFinished` is set,
   so `viewWillAppear` does **not** restart it (it only restarts a
   scan that is still `_scanning` and cancelled, or one finished
   > 60 s ago). The screen therefore sits on the partial 6-item list
   indefinitely until the user pulls to refresh or re-enters after a
   minute. To the user that reads as "the scan only finds 6 items".

A second, narrower defect in the same area: the expiration handler
read the *current* `_scanCancellation` / `_cleanCancellation` ivar at
fire time. A background task registered by a superseded scan can
therefore cancel the *newer* scan that adopted the task (the publish
block returns early on a generation mismatch without ending the task,
so the next scan's `WQCacheBeginBackgroundTask` returns early and the
old task — and its handler — stays live). That is a real race, though
it needs a superseded scan plus a > 30 s backgrounding to fire.

## What I changed (`WQCache.m`)

- **An interrupted scan now restarts itself (bounded).** In the
  publish block, if the scan was interrupted and the user is still
  looking at the screen (foreground, view in a window) and no clean
  is running, the scan restarts after 0.5 s, up to 3 consecutive
  auto-restarts (`_interruptedRestarts`, reset on a complete scan and
  on a user-initiated rescan in `viewWillAppear` / `userRefresh`). A
  scan that keeps being interrupted stops retrying; the user can still
  pull to refresh. This fixes the stuck-at-6-items symptom regardless
  of what interrupted the first pass.
- **The expiration handler cancels only its own token.** Both the
  scan and the clean handlers now capture the `WQScanCancellation`
  created for that run (`[cancellation cancel]`) instead of reading
  `_scanCancellation` / `_cleanCancellation` at fire time. A stale
  task can no longer kill a newer scan. The cross-cancellation (scan
  handler cancelling the clean and vice versa) is removed: each run
  is protected by its own task, and scan/clean never overlap (the UI
  prevents it), so the cross-cancel was redundant.
- **Diagnostic log line.** The publish block now logs
  `cache scan: found N items (X), interrupted=0/1, failed
  enumerations=N, kept previous=0/1`, so the next device log shows
  exactly what a scan found and why, instead of leaving the cause to
  be inferred from the item count.

The background-task and log-clear changes from §1–2 are untouched
(the user has not reported them broken; the log-clear button was
confirmed working on-device).

## What to check on-device after installing (CN4)

1. Open Cache Cleanup and let the scan finish: it should again find
   ~210 items / ~20 GB (the 6-item result should not recur). If it
   still shows few items, send the `cache scan: found …` log line —
   it says whether the scan was interrupted, whether an enumeration
   failed, and whether the previous list was kept.
2. Switch to another app mid-scan and come back: the list should
   complete by itself (auto-restart) instead of sticking at a partial
   count, and the log should show the interrupted scan followed by a
   completing one.
3. The background-switch and log-clear behaviour from §1–2 is
   unchanged; re-verify only if the user reports a problem there.
