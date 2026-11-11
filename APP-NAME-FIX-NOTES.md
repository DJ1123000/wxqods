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
