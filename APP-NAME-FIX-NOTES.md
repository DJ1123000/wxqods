# App display names: general fix (replaces the 17-app pin)

## What the user saw

On iOS 26.4.1 the Apps list and the Cache Cleanup list showed wrong-language
app names: WeChat (`com.tencent.xin`) as "Kod sumber Fortran" (Indonesian),
QQ (`com.tencent.mqq`) as "iOS-simulaattori" (Finnish), Twitter as Russian
"Симуляторы", Chrome as Hindi "रेसिंग गेम", a GIF app as "preprocessed C
source code", one app as "Macmini3,1", another as "public.app-…usic-games"
(an App Store category UTI), one as "�iPod classic�", one as an Arabic/Urdu
"AirPods (charging case…". The app's own UI was already Chinese; only the
app names were wrong. A stopgap build (CN2, commit b485231) pinned 17
well-known bundle IDs to their real names; the user rejected per-app
hardcoding and asked for a real general fix. That stopgap is removed here.

## Root cause (as understood)

WQFiles reads app names by parsing the LaunchServices database (CSStore2,
magic `bdsl`) found in an Internal Daemon container. Bundle records are
parsed with several candidate layouts (27.0, 26, 27.2, 27.2b/c/d); the
layout that maps the **most containers** wins. The display name is read at
that layout's `displayName` offset (iOS 26 layout: record 0x23c, display
name at +0x70).

Two problems, both in `WQLaunchServices.m`:

1. **The layout is scored only on container mapping, never on name
   quality.** The bundle-ID and container offsets can be right (so all 313
   containers map and the bundle IDs shown are correct) while the
   display-name offset is wrong. The string reference read at that offset
   resolves to some *other* string in the store's string table — a UTI
   description, an App Store category, a hardware model, a localized name
   in a random language. That is exactly the observed garbage: every one
   of those strings is a plausible "name" of *something else*. The iOS 26
   record layout evidently differs on 26.4.1 from the 26.0 layout the
   parser was derived from (or the winning layout is a 27.x one whose name
   offsets do not apply to 26.4.1). The CSStore2 format is undocumented,
   so there is no documented 26.4 layout to correct the parser against;
   I could not determine the true 26.4.1 offset without the device's
   database file.
2. **Nothing validated the display name.** Any string that passed
   `wq_safe_name` (no control/format characters, not a path) was accepted,
   so a UTI or a half-decoded string was shown as if it were the app's name.

The Cache screen uses the same `wq_display_name(bid)` path
(`WQCache.m:633`), so it was garbled the same way.

## What I implemented (no per-app table)

**Primary source: the app bundle's own Info.plist** — the same source
SpringBoard shows, and the same file the icon loader (`wq_bundle_icon`
in `WQUI.m`) already reads with a `wq_grant` fallback. The comment that
"the app bundles cannot be opened" is wrong for iOS 26 user apps: the
bundle path comes from the LaunchServices snapshot (`snapshot.bundlePaths`,
already parsed), and `wq_grant` (worse_query sandbox extension) makes it
readable, exactly as icons already do.

New function `wq_bundle_display_name(bundleID, snapshot)` in
`WQLaunchServices.m`:

- Reads `<bundle>/Info.plist` (retry after `wq_grant(bundlePath)`).
- Tries the localized name first: for each of `[NSLocale
  preferredLanguages]` in order, tries `<lang>.lproj/InfoPlist.strings`
  (`CFBundleDisplayName`), with `.lproj` candidates derived per language
  (`zh-Hans-CN` → `zh-Hans-CN`, `zh-Hans`, `zh`, plus underscore forms;
  `en-US` → `en-US`, `en`). So a Chinese device gets 微信/抖音, an
  English device gets the English name.
- Falls back to Info.plist `CFBundleDisplayName`, then `CFBundleName`.
- Sanitizes with the existing `wq_safe_name`.
- Caches by bundle path (a reinstalled app gets a new path, so a stale
  entry is never reused; cache capped at 4096 entries). The first few
  resolutions are logged as `names: bundle: <bid> -> <name>` so a device
  run shows the source working.

**Fallback chain** (when the bundle cannot be read), in
`wq_display_name` / `wq_known_name`:

1. Bundle localized name (above).
2. Built-in Apple table (kept; system apps live in `/Applications`,
   which is not listable, so their bundles are unreadable and the table
   is still needed). **The 17 third-party pins are removed.**
3. LaunchServices store display name — but only if it passes the new
   `wq_ls_display_plausible` check, which rejects: text containing the
   U+FFFD replacement character (bad decode), anything starting with
   `public.` (UTI domain), anything containing `.app-category`, and bare
   reverse-DNS identifiers (all-lowercase identifier characters, ≥2 dots,
   no spaces). A rejected display name falls through instead of being
   shown.
4. LaunchServices store bundle name (`CFBundleName`, e.g. "WeChat") —
   a real if unlocalized name, always better than a UTI or a wrong-language
   string.
5. Closest parent app (existing logic; the parent now gets the same full
   resolution, bundle first).
6. Bundle ID (the callers' existing fallback).

Also in `wq_display_name`: the bundle ID is trimmed of surrounding
whitespace/newlines before any lookup (see Aweme note below).

## The Aweme anomaly (why the pin worked for WeChat/QQ but not Douyin)

In the Cache list on CN2, Douyin (`com.ss.iphone.ugc.Aweme`) showed its
bundle ID (truncated, plus an emoji) instead of the pinned 抖音, while
WeChat/QQ showed correctly. `wq_display_name` returns the pinned name
for an exact key match, so the bundle ID handed to it for that container
must **not** have been exactly `com.ss.iphone.ugc.Aweme` — most likely
the container label (`wq_container_label`) returned a variant for that
container (a different label source, or invisible trailing characters
from the container attribute, which would also explain the trailing
emoji: a string carrying an invisible/emoji suffix fails the exact
dictionary lookup and falls back to the raw label). I could not confirm
which label source produced it without the device. Two mitigations are
in this fix: the ID is trimmed before lookup, and the name is now
resolved from the bundle (not from matching the ID against a table), so
a slightly-off label no longer blocks the correct name as long as the
bundle path resolves. If Douyin still shows wrong after this build, the
`names:` log lines (below) will show what ID and path were used.

## What I could NOT verify (no Mac / no device here)

- The fix is **not compiled**: this Linux VM has no Xcode. Bracket
  balance and format-string consistency were checked by hand/grep only.
  The real build must run on GitHub Actions (macos-latest) as before.
- Whether every user-app bundle's Info.plist is actually readable via
  `wq_grant` on iOS 26.4.1. The icon loader proves it for at least some
  apps (one real icon loaded in the user's screenshot); if some bundles
  refuse, those apps fall back to the (now validated) store name or the
  bundle name — no worse than today, but possibly still garbled for those
  apps.
- Whether `InfoPlist.strings` in the old OpenStep text format parses via
  `NSDictionary dictionaryWithContentsOfFile:` on device. Modern apps ship
  it compiled to binary plist, which parses; very old apps ship the text
  form, which `NSPropertyListSerialization` also accepts, but I could not
  test it.
- The true iOS 26.4.1 CSStore2 record layout (no documentation exists).
  The parser is deliberately left untouched except for the validation
  above; if the layout is ever corrected, the store path becomes
  trustworthy again and the bundle path is only a (correct) primary.
- `LSApplicationWorkspace` / `LSApplicationProxy.localizedName` was
  considered as the primary source: the workspace API already works on
  iOS 26 (this app uses it to build `gLSAPILabels`), and `localizedName`
  is the authoritative localized name, but it costs one IPC call per app
  (~2 ms × 300 apps) and is refused on iOS 27. The bundle route is
  faster, needs no IPC, and works on both. If bundle reading ever proves
  unreliable, `localizedName` is the natural next primary.

## Tests

`tests/WQLaunchServicesTests.m` (macOS test binary, needs Xcode to run):

- Added a `wq_grant` test double (returns `NO`; the test build does not
  link `WQAccess.m`, and the new code calls `wq_grant`).
- `TestDisplayNamePlausibility`: a UTI-like display name
  (`public.app-category.music-games`), a bare reverse-DNS identifier
  (`com.example.something`), and a name containing U+FFFD all fall back
  to the bundle name; a normal localized name still wins.
- `TestBundleDisplayName`: a synthetic store whose bundle record points
  at a temporary `.app` bundle; the base `Info.plist`
  `CFBundleDisplayName` wins over a UTI-like store name, and a localized
  `InfoPlist.strings` (in the `.lproj` of the test machine's first
  preferred language) wins over the base name.
- Existing tests are unchanged in expectation; the store fixtures have no
  bundle path, so they exercise the fallback chain as before.

## What to check on-device after installing

1. Apps list and Cache Cleanup list: WeChat, QQ, Douyin, Chrome, 抖音,
   QQ音乐, 网易云音乐, 闲鱼, X, 高德地图 etc. should show their real
   (Chinese where the app ships it) names. Apps not in any table and
   whose bundle cannot be read will show the bundle name (e.g. "WeChat")
   instead of a wrong-language string.
2. Open the in-app Log and look for lines starting with `names:`:
   `names: bundle: <bundle-id> -> <name>` (first 8 bundle resolutions)
   confirms the bundle route is working; `names: sample: …` and
   `names: store …` show the store parse as before. If an app still
   shows wrong, send the `names:` lines plus that app's bundle ID.
3. If Douyin still shows its bundle ID instead of 抖音, that points at
   the container label (not the name lookup); the log line for its
   container will help pin it down.

---

# Follow-up: CN3 did not work on-device (2026-11-11, iOS 26.4.1)

## What the device log proved

The user installed CN3 and sent the device log (WQ Files 0.8 (36),
iPhone 17 Pro Max, iOS 26.4.1). The Apps list still showed the exact
same garbled names (WeChat = "Kod sumber Fortran", Chrome = Hindi,
X = Russian, etc.), and the log contained **zero** `names: bundle:`
lines even though 313 apps were measured — so `wq_bundle_display_name`
never resolved a single name. The container enumeration itself works
(314 containers) and the LS store parse works (314 apps, 1142
extensions, 21 daemons). Only the bundle-path / Info.plist chain is
dead. One AppGroup container (`885A895E-…`) gives "Operation not
permitted" on its metadata plist; that is a single restricted group
container, not an app container, and does not explain the names.

## Corrected root cause

The CN3 note above was wrong in two places:

1. **`snapshot.bundlePaths` is empty on iOS 26.4.1.** The bundle path is
   read at record offset `+0x00` in every layout in `kWQLSLayouts`
   (`r[4] = wq_rd32(u + L->bundlePath)` with `bundlePath = 0x00`). That
   offset is the **iOS 27 record layout** — the regression test
   `StoreWithBundlePath` writes the path at +0x00 and passes, because it
   was built against the 27.0 layout. On iOS 26.4.1 the first u32 of the
   record body is not a bundle-path string reference, so no `.app` path
   ever resolves into `layoutBundlePaths`, `wq_bundle_display_name`
   returns nil before touching a file, and the Info.plist read never
   starts. The CN3 fix therefore changed nothing on 26.4.1. The
   display-name offset has the same problem (it yields wrong-language
   strings), so the whole 26.4 record layout differs from the layouts
   the parser knows; the true 26.4.1 bundle-path offset is unknown and
   is not guessed here.
2. **The icon evidence did not prove bundles can be opened.** The one
   real icon in the CN3 screenshot came from the system API
   `UIImage _applicationIconImageForBundleIdentifier:format:scale:`
   (`wq_real_icon` in `WQUI.m`), not from reading the bundle — the icon
   loader's bundle path (`wq_bundle_icon`) was nil for the same reason
   (empty `bundlePaths`), which is why most icons are the grey-gear
   fallback. Bundle readability on 26.4.1 was never proven and is still
   an open question; the new loaders below decide it at runtime.

## New approach (this change, CN4)

The name no longer depends on the CSStore2 record layout at all. Three
independent sources, tried in order in `wq_display_name`:

1. **LaunchServices API `localizedName`** (`wq_lsapi_name_map` in
   `WQLaunchServices.m`): one `LSApplicationWorkspace
   .allInstalledApplications` call (the same call the shared scan
   already uses for container labels) also answers `localizedName` —
   the authoritative localized name, Chinese on a Chinese device — and
   `bundleURL`, the real `.app` path. It is refused on iOS 27, but on
   iOS 26 it is the cheapest correct source. Loaded once and cached;
   the log line `names: LSAPI: N apps, M names, K bundle paths` (plus
   first-8 `names: lsapi:` samples) shows whether it answered.
2. **The bundle's own Info.plist** (`wq_bundle_display_name`, now
   reading the path from `wq_bundle_path_for_id`): the path comes from
   the API's `bundleURL`, from the Bundle directory listing below, or
   from the store record (iOS 27). The localized resolution is unchanged
   (localized `InfoPlist.strings` → `CFBundleDisplayName` →
   `CFBundleName`), factored into `wq_info_display_name`.
3. **Bundle directory listing** (`wq_bundle_dir_map`): lists
   `/private/var/containers/Bundle/Application/` (with a `wq_grant`
   first) and reads each `.app/Info.plist` for its
   `CFBundleIdentifier`, building bundle id → `.app` path. Whether the
   directory is listable depends on the sandbox escape; a failure is
   logged once (`names: bundle dir unavailable: …`) and not retried.
   This also feeds `wq_bundle_path_for_id`, so if it works the icon
   loader gets real bundle paths too.
4. **Store fallback, now validated much harder** (`wq_known_name`):
   built-in Apple table → LS store display name (only if plausible)
   → LS store bundle name (`CFBundleName`, e.g. "WeChat") → parent
   fallback. The bundle name is now preferred over any suspect display
   name: a wrong-language string is never shown when the (English)
   bundle name exists.

## Strengthened plausibility check

`wq_ls_display_plausible(name, bundleName)` now takes the LS bundle
name and cross-checks against it. It rejects:

- `public.` prefix, `.app-category` (existing);
- any name containing "simula" (case-insensitive — "simula", not
  "simulat", because the Finnish "simulaattori" has a double `a` and
  does not contain "simulat") and device-model identifiers
  ("Macmini3,1", "iPhone18,2": letters, digits, comma, digits);
- a replacement character **unless the name also contains CJK**
  (see the test note below);
- **any letter in a script other than Latin or CJK**
  (`wq_name_script_ok`): Hebrew, Cyrillic, Arabic, Devanagari, Thai,
  Tamil, etc. are rejected; Latin and CJK (Han, Hiragana, Katakana,
  Hangul) pass. Astral characters are rejected except CJK Extension B,
  so emoji (e.g. the "😡" in the Aweme label) is rejected too;
- bare reverse-DNS identifiers (existing);
- **a multi-word Latin phrase (≥3 words) that shares no word with the
  bundle name** (`wq_name_tokens` splits on non-alphanumerics and on
  camelCase boundaries, so "App Store" shares "app"/"store" with
  bundle name "AppStore"). The check is on the English/ASCII side
  only and is skipped for names containing CJK, so display "微信" vs
  bundle name "WeChat" always passes, and two-word names ("App Store",
  "Fresh name") are left alone.

Every garbage string observed on-device is rejected by at least one of
these rules, and the rule set was validated in Python against 31 cases
(all pass), including the legitimate names WeChat/QQ音乐/抖音/X/Chrome/
Google Chrome/Microsoft Word/App Store and the existing regression-test
expectations.

## Two test corrections found while doing this

- **CN3's blanket U+FFFD rejection broke an existing test.**
  `TestRefreshAndUnicodeSafety` expects "Café 日本 �evil" to win; the
  U+FFFD there comes from `wq_safe_name` sanitizing a bidi override
  (U+202E) inside a real localized name, not from a decode failure.
  The rule is now: reject U+FFFD only when the name contains no CJK
  (a purely-Latin name with a replacement character did not decode).
  `TestDisplayNamePlausibility`'s "Bad�Evil" (no CJK) is still
  rejected, and "Café 日本 �evil" (has CJK) is accepted.
- **U+FFFD is above the fullwidth range.** `wq_name_script_ok`
  originally allowed `0xFF00–0xFFEF`, but U+FFFD is 0xFFFD = 65533
  while 0xFFEF is 65519, so the replacement character was rejected by
  the script check even when the U+FFFD rule tolerated it. It is now
  allowed explicitly in the script check (the plausibility function
  decides it).
- New test cases in `TestDisplayNamePlausibility` cover the observed
  garbage ("Kod sumber Fortran", "preprocessed C source code",
  "iOS-simulaattori", "Macmini3,1", Hebrew "מגדל", Russian
  "Симуляторы", Hindi "रेसिंग गेम" → all fall back to "Example") and
  the token-sharing / two-word exceptions ("Example App Pro",
  "App Store" still win).

Note: the tests run in CI only if `tests/run_all_tests.sh` is
executable in the GitHub repo (`build.sh` skips the suite silently when
`-x` fails; the Contents API stripped exec bits before — `build.sh`
needed a manual mode fix). If the suite was skipped for CN3, that is
how a test-breaking change shipped green. Worth verifying the mode on
the repo before the next build.

## What to check on-device after installing (CN4)

1. Apps list and Cache Cleanup list: real names (Chinese where the app
   ships it). If a name is still wrong, it is now a bundle name
   (e.g. "WeChat") rather than a wrong-language string.
2. Open the in-app Log and look for:
   - `names: LSAPI: N apps, M names, K bundle paths` — if M and K are
     near 300, the API route works and names should be correct.
   - `names: bundle dir: N apps` — if the Bundle directory was
     listable; `names: bundle dir unavailable: …` if not.
   - `names: bundle: <bid> -> <name>` (first 8) — bundle Info.plist
     resolutions.
   - `names: lsapi:` / `names: bundledir:` samples (first 8 each).
   If LSAPI reports 0 names AND the bundle dir is unavailable, the
   names fall back to the validated store name / bundle name; send the
   `names:` lines so the next step can be chosen (the remaining option
   would be self-calibrating the 26.4 record offset by scanning record
   bodies for a `.app` path reference, which was not attempted here).

---

# Follow-up: CN4 did not work on-device (2026-11-11, iOS 26.4.1) — CN5

## What the device log proved

The user installed CN4 and sent the device log (WQ Files 0.8 (36),
iPhone 17 Pro Max, iOS 26.4.1). The Apps list still showed the exact
same garbled names (WeChat = "Kod sumber Fortran", Douyin = bundle ID
+ 😡). The log lines that matter:

```
scan: LaunchServices API: 0 apps and 0 plug-ins, 0 data containers
names: LSAPI: 0 apps, 0 names, 0 bundle paths
names: bundle dir unavailable: The file "Application" couldn't be opened because you don't have permission to view it.
names: bundle: com.apple.freeform -> Freeform   (8 Apple apps only)
icon: com.burbn.instagram: can't read /private/var/containers/Bundle/Application/127E18F1-7AC5-426E-A8C7-074BCA51C1F5/Instagram.app/Info.plist (Operation not permitted)
icon: com.apple.store.Jolly: can't read /private/var/containers/Bundle/Application/9D1198BB-DB31-454E-A729-7C856AF1748F/Apple Store.app/Info.plist (Operation not permitted)
names: store 13.5 MB, layout 26: 453 bundle and 2479 plugin records, 239 names, 3 of 1539 container paths mapped
names: layout hint (record size@container offset): 0xe8@0x60 x1204, 0x104@0x4c x1074, 0x100@0xb4 x849, 0x60@0x18 x744, 0x60@0x54 x727, 0x48@0x10 x703, 0x40@0x4 x524, 0x60@0x50 x405
names: sample: com.apple.mobilesafari = متن کا انتخاب, com.apple.Preferences = Файл за проследяване на ядрото Darwin, com.apple.camera = opcije pretraživanja, com.apple.mobilenotes = ਅੱਖਰ ਫ਼ਾਰਮੈਟ
cache scan: found 16 items (302 MB), interrupted=0, failed enumerations=0, kept previous=0
```

## Corrected root cause (this replaces the CN3 conclusion above)

1. **LSAPI is DEAD on 26.4.1.** `LSApplicationWorkspace
   .allInstalledApplications` returns 0 apps. The CN4 LSAPI route
   returns nothing. It stays in the code only as a best-effort first
   try that is expected to fail here (it may work on other iOS 26
   versions or on iOS 27 where the API is refused entirely).
2. **Bundle-directory listing is DEAD.** `/private/var/containers/
   Bundle/Application/` cannot be opened (permission denied). The
   CN4 bundle-dir route returns nothing.
3. **Third-party bundle Info.plist is UNREADABLE.** The store record
   DOES give the bundle path (Instagram's and Apple Store's paths
   above are real), but reading `Info.plist` at that path fails with
   "Operation not permitted". This is a sandbox restriction, not a code
   bug. The whole "read the bundle's Info.plist" approach is
   fundamentally blocked for third-party apps. Only APPLE apps' bundles
   are readable (Freeform, AppleTV, Weather, Contacts, VoiceMemos,
   FaceTime, VoiceOverTouch, Magnifier all resolve via bundle read —
   those live in `/Applications/`, world-readable).
4. **The CN3 conclusion "snapshot.bundlePaths is empty" was WRONG.**
   The bundle-path offset `+0x00` IS correct — the path is parsed and
   is in `snapshot.bundlePaths` (see the Instagram/Apple Store paths
   above). The path is there; the READ is blocked. The CN3 fix failed
   because the Info.plist read was sandbox-blocked, not because the
   path was missing. This note corrects that.
5. **The layout "26" in `kWQLSLayouts` is WRONG for this store.** It
   was chosen because it mapped the most containers, but the layout
   hint shows the real records are mostly **0xe8 bytes (232) with
   container at 0x60** — 1204 records — plus other sizes (0x104,
   0x100, 0x60, 0x48, 0x40). A 0x23c-byte layout cannot be right for
   0xe8-byte records. That is why the display names are garbage: the
   field offsets are wrong for the real record size. The `names: sample`
   line confirms it (Safari/Preferences/Camera/Notes all show
   wrong-language strings). The layout scoring never checked name
   quality, so a layout with wrong name offsets won on container count.
6. **Log-clear trap (also fixed here).** `wq_bundle_display_note`'s
   static 8-note counter was never reset by `wq_log_clear`, so after
   the user cleared the log once, no `names: bundle:` line could ever
   reappear. The counters are now file-level statics, reset by
   `wq_bundle_display_note_reset()` (declared in `WQLaunchServices.h`),
   which `wq_log_clear()` in `WQAccess.m` calls. A fresh log after
   clearing now shows the bundle resolutions again.

## New approach (this change, CN5)

### 1. Self-calibrated 26.4 layout + anchor validation

All known layouts share one pattern: name = container+4,
displayName = name+8, bundle id at +0x0c, bundle path at +0x00.
The most common record is 0xe8 with container at 0x60, so the 26.4
layout is `{ "26.4", 0xe8, 0x0c, 0x60, 0x64, 0x6c, 0x00, 0x104,
0x00, 0x4c }` — name at 0x64, displayName at 0x6c, bundleID at
0x0c, bundlePath at 0x00, all inside the 232-byte record. The
0x104 plugin records have container at 0x4c (from the hint).

Layout selection now scores **anchor correctness first**
(`wq_ls_anchor_score`): for four Apple apps whose bundle name is
known (com.apple.mobilesafari→"MobileSafari",
com.apple.Preferences→"Preferences", com.apple.camera→"Camera",
com.apple.mobilenotes→"MobileNotes"), it checks whether the layout's
name field resolves to that exact bundle name. A layout with wrong
name offsets scores 0 and cannot win, no matter how many containers
it maps. Ties fall back to container count, then plausible-name count,
then total name count. A new log line records the choice:
`names: layout %@ anchor %lu/4, %lu plausible names`.

This makes the parser self-calibrating: if the 0xe8 offsets are
right, the anchor score is 4/4 and the names are correct; if the
hypothesis is wrong, the anchor score is 0/4 and the log says so
instead of silently showing garbage.

### 2. Store bundle name (CFBundleName) is the primary name for third-party apps

Since Info.plist is unreadable, LSAPI is dead, and the bundle dir is
dead, the store's bundle name is the only readable correct identifier
left for third-party apps. `wq_known_name` now returns the store
bundle name (after `wq_bundle_name_ok` — single token/camelCase, not
a description, not a UTI, not wrong-language, not a device model,
<3 words) whenever the LS display name is not plausible. The
resolution order in `wq_display_name` is now:

1. LSAPI `localizedName` (best effort, expected to fail on 26.4.1).
2. Bundle Info.plist (works for Apple apps in `/Applications/` only).
3. Store display name — **only if plausible** (see below).
4. Store bundle name (`CFBundleName`, e.g. "WeChat") — the English
   internal name, always better than a wrong-language string.
5. Parent app (same resolution).
6. Bundle ID (callers' existing fallback).

### 3. Name priority (user directive, 2026-11-11)

"把错误排除，优先搞定中文，其次再显示英文" — eliminate the wrong
names first; correct **Chinese** first; correct **English** second;
never show a wrong-language garbage string. So:

- **Chinese first:** a trustworthy Chinese display name (from a
  calibrated store offset, or from a readable Info.plist) wins.
  CJK names always pass the plausibility check.
- **English second:** when no trustworthy Chinese name exists, the
  English bundle name (CFBundleName, e.g. "WeChat", "QQ", "Chrome")
  is shown. A correct English bundle name is always better than a
  wrong-language display name.
- **Garbage never:** a suspect display name never beats a known
  bundle name. If neither a plausible display name nor a sane bundle
  name exists, the name falls back to the parent app or the bundle ID
  — never to a wrong-language string.

### 4. Why "Kod sumber Fortran" survived CN4 (and how it is fixed)

For WeChat (`com.tencent.xin`) on CN4, `wq_known_name` was called
with display "Kod sumber Fortran" and bundleName from the store.
The old multi-word rule compared the display against the bundle
name — but the bundle name field was empty/nil for that record
(the 26 layout's name offset 0x68 read a wrong string, and the
"239 names" in the log covers only the records whose name field
resolved at all). With bundleName nil, the multi-word rule had
nothing to compare against, so "Kod sumber Fortran" passed as a
"plausible" 3-word Latin phrase.

Fixed two ways:

- `wq_ls_display_plausible` now takes `(name, bundleName,
  bundleID)`. When the bundle name is unknown, it falls back to
  comparing the display's tokens against the **bundle ID**'s tokens
  (`wq_bundle_id_tokens`: splits the reverse-DNS ID, drops generic
  segments com/apple/app/ios/iphone/ipad/mac/macos/watch/tvos, keeps
  segments ≥2 chars). For WeChat, the ID `com.tencent.xin` gives
  {tencent, xin}, which shares nothing with {kod, sumber, fortran},
  so the display is rejected even with bundleName nil.
- Even if a display name somehow passed, `wq_known_name` now
  prefers the bundle name whenever the display is not plausible —
  and the bundle name is checked with `wq_bundle_name_ok` before
  use, so a garbage bundle name cannot be shown either.

The rule set was re-validated in Python against 36 cases (0 fails),
including all observed garbage and the legitimate names
WeChat/微信/抖音/QQ音乐/X/Chrome/Google Chrome/Microsoft Word/App
Store and the existing regression-test expectations ("Café 日本
�evil", "Retry 日本", "Example App Pro", "App Store").

## What the new resolution does per app (Info.plist unreadable, LSAPI dead, bundle-dir dead)

- **WeChat** (`com.tencent.xin`): store display "Kod sumber
  Fortran" is rejected (no shared token with bundle name "WeChat"
  or ID tokens {tencent, xin}); bundle name "WeChat" is shown.
  If the 0xe8 offsets are correct, the store display is the real
  Chinese 微信 and that wins instead.
- **Instagram** (`com.burbn.instagram`): Info.plist read is
  "Operation not permitted"; bundle path is known from the store but
  unreadable. Same path as WeChat: garbage display rejected, bundle
  name "Instagram" shown; correct Chinese display (if the 0xe8
  offsets are right) wins.
- **Chrome** (`com.google.chrome.ios`): same — Hindi display
  rejected by the script check; bundle name "Chrome" shown; correct
  Chinese/English display wins if the offsets are right.
- **抖音** (`com.ss.iphone.ugc.Aweme`): same — bundle name "Aweme"
  shown (the internal name, not 抖音) unless the calibrated store
  display gives the real Chinese 抖音. The bundle-ID-plus-emoji label
  was a container-label issue, not a name-lookup issue; the name
  lookup now never returns a garbage string for it.

## Tests

`tests/WQLaunchServicesTests.m` (macOS test binary, needs Xcode to run):

- `Test26_4Layout`: a synthetic store with 0xe8-byte records
  (bundle id +0x0c, container +0x60, bundle name +0x64, display
  name +0x6c, bundle path +0x00). A Chinese display name ("微信")
  wins; a garbage display name ("Kod sumber Fortran") falls back
  to the English bundle name ("WeChat"); a plausible English display
  name still wins. The container maps to the bundle id.
- `TestDisplayNamePlausibility`: new cases with a store whose
  bundle-name field is absent (ref 0, so bundleName is nil):
  "Kod sumber Fortran" and "preprocessed C source code" are still
  rejected by the bundle-ID fallback, and `wq_display_name` returns
  nil (the caller shows the bundle id) — never the garbage string.
- Existing tests are unchanged in expectation. The store fixtures
  have no bundle path, so they exercise the fallback chain as before.
- `tests/run_all_tests.sh` must be executable in the GitHub repo
  (`build.sh` skips the suite silently when `-x` fails); it was
  mode 100755 after the CN4 fix.

## What I could NOT verify (no Mac / no device here)

- The fix is **not compiled**: this Linux VM has no Xcode. Bracket
  balance and format-string consistency were checked by script; the
  plausibility rules were validated in Python (36 cases, 0 fails).
  The real build must run on GitHub Actions (macos-latest) as before.
- **Whether the 0xe8 offsets are correct.** The layout is derived
  from the hint (0xe8@0x60) plus the shared pattern (name =
  container+4, displayName = name+8, bundleID +0x0c, bundlePath
  +0x00), but I have not seen a raw 0xe8 record. The anchor score
  (4 known Apple bundle names) is the runtime proof: if it is 4/4,
  the offsets are right; if it is 0/4, the hypothesis is wrong and
  the parser falls back to the old container-count ranking (garbage
  names, but the plausibility check still blocks them from showing).
- Whether the store's bundle-name field is populated for all 453
  bundle records (the log said "239 names" — that count is the number
  of records whose name field resolved to a string under the *old*
  layout; under the 26.4 layout the count may be higher). If a given
  app's bundle name is also missing, that app falls back to the
  bundle ID.
- Whether any third-party Info.plist is readable through a different
  grant (the log proves the normal `wq_grant` path is blocked for
  Instagram and Apple Store; other apps are assumed the same).

## What to check on-device after installing (CN5)

1. Apps list and Cache Cleanup list: WeChat should show 微信 (if the
   0xe8 offsets are right) or "WeChat" (if only the bundle name is
   available). It must **never** show "Kod sumber Fortran" again.
   Same for QQ, Chrome, 抖音 (抖音 or "Aweme"), X, Instagram.
2. Open the in-app Log and look for lines starting with `names:`:
   - `names: layout 26.4 anchor 4/4, N plausible names` — the
     0xe8 offsets are confirmed correct. If it says `anchor 0/4`,
     the offset hypothesis is wrong and the next step is to dump a
     raw 0xe8 record.
   - `names: sample: …` — should now show correct Chinese/English
     names (e.g. Safari = Safari, Preferences = 设置 or
     "Preferences"), not wrong-language strings.
   - `names: bundle: <bid> -> <name>` (first 8) — Apple apps via
     bundle read; after clearing the log, these lines reappear
     (the reset fix).
   - `names: LSAPI: 0 apps` and `names: bundle dir unavailable`
     are expected on 26.4.1 and are no longer a problem.
   If an app still shows wrong, send the `names:` lines plus that
   app's bundle ID.

# Follow-up: CN5 did not work on-device (2026-11-11, iOS 26.4.1) — CN6

## What the user saw (screenshots 18:06–18:08)

User verdict: "有进步但不多，依然存在问题" (progress but not much,
problems remain). Apple apps now mostly show correct English names
(Freeform, Maps, Numbers, Wallet, Games, Shortcuts, Preview, Tips,
Calculator, App Store, Keynote, Reminders, Stocks). Third-party apps
STILL show garbage:

- "text/x-uuencode" (com.ownbook.notes) — a MIME type, not a name
- "VNC interneto vieta" (V2Box, hossin.asaadi.V2Box) — Lithuanian, 3 words
- "Código de encabezado C" (maxpodApp) — Spanish, 4 words
- "kommaadskilte værdier" (uzvideoapp2) — Danish, 2 words
- "čtyřznakový kód" (com.apple.SOSBuddy) — Czech, 2 words
- "Sporto žaidimai" (location-spoofer) — Lithuanian, 2 words
- "vị trí web trên internet" (Hiddify) — Vietnamese, 5 words
- "csv_145x145@2x.png" (arrivo.app) — a FILENAME, not a name
- "EPUB 발행물" (nomad) — Korean
- "PlugInKit-liitännäinen" (Google Keyboard) — Finnish
- "ARKit-viitelisälaite" (globalrefresh) — Finnish

And some show the raw bundle ID instead of a name: com.apple.smsFilter,
com.ccb.ccbDemo, co.kitesim.app, com.zeptolab.cats, com.cmlink.esim.

## User's directive (followed exactly)

"直接底层代码首次验证即为中文，若没有，则摘取目录内例如taobao" —
directly in the underlying code, the FIRST validation must be Chinese.
If there is no Chinese name, then extract the name from the directory
(e.g. taobao).

His name priority (2026-11-11 17:41): "把错误排除，优先搞定中文，
其次再显示英文" — eliminate wrong names first; correct CHINESE names
first, correct ENGLISH bundle names second, NEVER show wrong-language
garbage.

## Why the CN5 plausibility check still leaked (traced in code)

The garbage reaches the screen through `wq_display_name` →
`wq_known_name` → `wq_ls_display_plausible`. The CN5 check failed in
four distinct ways, all in `WQLaunchServices.m`:

1. **Two-word phrases passed by design.** The multi-word rule only
   fired at `wordCount >= 3`, and its comment said a two-word name
   ("App Store", "Fresh name") "is a plausible app name and is left
   alone". That is what let "kommaadskilte værdier", "Sporto žaidimai"
   and "čtyřznakový kód" through.
2. **MIME types and filenames passed.** There was no rejection for a
   string containing "/" or ending in a file extension, and both
   "text/x-uuencode" and "csv_145x145@2x.png" are single tokens, so
   the multi-word rule never fired on them.
3. **The ≥3-word rule could not fire reliably.** It cross-checks the
   display name against the bundle name / bundle ID — but the bundle
   name comes from the same possibly-misaligned layout. When the
   winning layout is wrong, the name field is itself garbage and can
   share a token with (or equal) the display name, so the "shares a
   token" check passes vacuously. A string shares all its tokens with
   itself. This is the most likely path by which "VNC interneto vieta",
   "vị trí web trên internet" and "Código de encabezado C" reached the
   screen despite the ≥3-word rule. The cross-check assumes the bundle
   name is a trustworthy reference; under a wrong layout it is not.
   (The user never sent a CN5 log, so the anchor score — `4/4` vs
   `0/4` — is still unconfirmed; this mechanism is inferred from the
   code, not proven from a device log.)
4. **Korean/Japanese counted as "CJK".** `wq_name_has_cjk` counts
   Hangul and kana, so "EPUB 발행물" (Korean) bypassed the multi-word
   rule as a "real localized name", and `wq_name_script_ok` allows
   Latin Extended ranges, so Lithuanian/Danish/Czech/Vietnamese letters
   passed as "Latin". Single-token foreign words
   ("PlugInKit-liitännäinen", "ARKit-viitelisälaite") never triggered
   the multi-word rule at all.

## New approach (this change, CN6)

The restructure does not add more rules on top of the CN5 check — it
removes the store display name from the trusted set. The store display
name is now used ONLY when it is Chinese. Everything else comes from
the app's own bundle or its path.

New resolution order in `wq_display_name` (all in
`WQLaunchServices.m`):

1. **Chinese first, from any source** — the LSAPI localized name, the
   bundle Info.plist name, the built-in Apple name table, or the store
   display name. `wq_name_is_chinese` is stricter than
   `wq_name_has_cjk`: it requires a Han character AND no Hiragana /
   Katakana / Hangul, so Korean ("EPUB 발행물") and Japanese do not
   pass as Chinese. A Chinese store display must also pass
   `wq_ls_display_plausible` (the sanity gate).
2. **The app's own English name** — the LSAPI localized name, the
   bundle Info.plist name, or the built-in table. These are the app's
   own declared names, not the store display field. (On 26.4.1 LSAPI is
   dead and third-party Info.plists are unreadable, so this step is
   usually empty for third-party apps — which is exactly when step 3
   fires.)
3. **The bundle-path folder name** — `wq_bundle_path_name` takes the
   bundle path from the store record (`snapshot.bundlePaths`, known to
   resolve on 26.4.1, e.g.
   `/private/var/containers/Bundle/Application/<UUID>/Taobao.app`),
   takes its last path component, strips ".app". That gives a clean
   English name (WeChat, Taobao, Instagram). This needs no directory
   listing and no Info.plist read — the path string itself is enough.
4. **The store bundle name (CFBundleName)**, when `wq_bundle_name_ok`
   says it is sane.
5. **Nothing** — the caller falls back to the bundle ID (better than
   garbage).

New helpers:

- `wq_name_is_chinese(name)` — Han present, no kana/Hangul.
- `wq_display_name_sane(name)` — the hard gate, shared by every
  candidate: rejects UTIs / App Store categories, reverse-DNS ids,
  strings containing "/" (MIME types), strings ending in a known file
  extension or containing "@2x"/"@3x" (filenames), simulator words,
  device models, undecodable text (U+FFFD without CJK), and
  non-Latin/CJK scripts.
- `wq_bundle_path_name(bundlePath)` — the ".app" folder stem, or nil.

`wq_ls_display_plausible` now calls `wq_display_name_sane` and the
multi-word rule fires at **≥2 words** (not ≥3) when neither word is
shared with the bundle name or bundle ID tokens. It is now only the
second gate for a Chinese candidate, not the main defense.
`wq_known_name` was removed; its logic lives in `wq_display_name` so
that a Chinese name from any source is checked before any English
name. The stale comment in `wq_bundle_path_for_id` (claiming the
store record yields no bundle path on 26.4.1) was corrected — the
bundle path DOES resolve there and is now a primary name source.

## What the new resolution does per observed app

Assuming the store record's bundlePath resolves (it does on 26.4.1
per the CN4 log) and the Info.plist is unreadable (third-party apps):

| App | CN5 showed | CN6 shows |
| --- | --- | --- |
| WeChat (com.tencent.xin) | "Kod sumber Fortran" | 微信 (if the store display is Chinese) or "WeChat" (folder name) |
| V2Box (hossin.asaadi.V2Box) | "VNC interneto vieta" | "V2Box" |
| Hiddify | "vị trí web trên internet" | "Hiddify" |
| location-spoofer | "Sporto žaidimai" | "LocationSpoofer" (folder name; the real .app folder name is whatever the bundle is called — if it is "LocationSpoofer.app" this is exact) |
| Taobao (com.taobao.taobao4iphone) | (garbage) | "Taobao" |
| ownbook notes | "text/x-uuencode" | "Notes" |
| arrivo | "csv_145x145@2x.png" | "Arrivo" |
| nomad | "EPUB 발행물" | "Nomad" |
| Google Keyboard | "PlugInKit-liitännäinen" | "Gboard" |
| globalrefresh | "ARKit-viitelisälaite" | "GlobalRefresh" |
| com.apple.smsFilter etc. | raw bundle ID | raw bundle ID (unchanged — no path/name available; still better than garbage) |

## Tests

- `tests/WQLaunchServicesTests.m`: new `TestCN6GarbageFallback` with
  all 11 observed CN5 garbage strings plus the Taobao case — each must
  resolve to the bundle-path folder name, never the garbage; a Chinese
  display still wins over the folder name; two-word foreign phrases
  are rejected even without a bundle path (nil → caller shows bundle
  ID). `StoreWith26_4Record` now takes a bundlePath parameter.
- Three existing expectations changed to the CN6 behavior (the store
  display is never used unless Chinese, so even a plausible English
  display falls back): "Fresh name" → "Example", "Example App Pro" →
  "Example", "App Store" → "Example" (all in the no-bundle-path
  fixture, where the bundle name is the fallback).
- Python mirror validation (`/tmp/cn6_validate.py`, 32 cases, 0
  failures): all 11 garbage strings → folder name, Chinese wins,
  Info.plist English still beats the folder name when readable,
  no-path garbage → bundle name or nil.
- Bracket balance + format-string placeholder checks pass on both
  files touched. No ObjC compile was possible on this Linux VM (no
  clang/xcrun; the build runs on GitHub Actions macOS with
  `-Wall -Wextra -Werror`) — the CI build is the compile check.

## What I could NOT verify (no Mac / no device here)

- That the ObjC compiles (see above — CI build is the check).
- That the 26.4 layout's display-name offset is right (anchor 4/4 vs
  0/4 still unconfirmed — the user never sent a CN5 log). CN6 no
  longer depends on it for third-party apps: the display name is only
  used when Chinese, and the folder name does not depend on the
  name/display offsets at all (only on bundlePath at +0x00, which is
  confirmed to resolve). If the layout IS wrong, the only visible
  effect is that Chinese store display names may be missed and apps
  show their English folder name instead — still correct, never
  garbage.
- The real .app folder name for location-spoofer (assumed
  "LocationSpoofer.app" in the test; the on-device name is whatever
  the bundle folder is called — it will be shown as-is).

## What to check on-device after installing (CN6)

1. Apps list and Cache Cleanup list: WeChat should show 微信 or
   "WeChat" — never "Kod sumber Fortran". V2Box should show "V2Box",
   Hiddify "Hiddify", Taobao "Taobao", location-spoofer its folder
   name. No MIME types, no filenames, no wrong-language phrases
   anywhere in the list.
2. Open the in-app Log and look for lines starting with `names:`:
   - `names: layout 26.4 anchor 4/4, N plausible names` — the 0xe8
     offsets are confirmed correct. If it says `anchor 0/4`, the
     offset hypothesis is wrong, but CN6 still shows folder names, so
     this is now informational only.
   - `names: bundle: <bid> -> <name>` (first 8) — Apple apps via
     bundle read; after clearing the log, these lines reappear.
   - `names: LSAPI: 0 apps` and `names: bundle dir unavailable`
     are expected on 26.4.1 and are no longer a problem.
   If an app still shows wrong, send the `names:` lines plus that
   app's bundle ID and its .app folder name (visible in the log's
   `names: bundle:` lines only for readable bundles; otherwise from
   the Apps list's container path).
