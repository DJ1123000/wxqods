> **Requires:** iOS 27. Tested on iOS 27.0.1 (iPhone 17 Pro Max); other iOS 27 versions are untested.
> **Needs:** a sideloading tool that keeps the App Group entitlement. If the Log says "No App Group", re-sign with one that does; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.6

## Cooler, faster scans

- **One scan instead of three.** Apps, extensions and the app name database are found in a single pass, which is reused for 10 minutes. Pull down on Apps, Cache Cleaner or a folder to scan again, for example after installing an app.
- **Scans run cooler.** They use at most four CPU cores at a lower priority, so the device stays cooler on phones with many files.
- **No more "stuck at 100%".** The first time app names are loaded, the screen shows "Reading app names…" instead of standing still at "Finding apps… 100%".
- **If the app name database isn't found**, WQ Files doesn't search again at every start, only after a day or when you pull to refresh.

## New

- **Manage your backups.** Tools → **App Backups** opens the app backups directly. Delete a single backup, or select several (Select / Select All) and delete them together. Deleting always asks first and can't be undone.
- **Stop a cache clean** while it runs. The Cache Cleaner stops after the current item and tells you how much was freed.
- **Cancel a ZIP export** while it's being prepared, instead of waiting for it to finish.
- **iPad:** all orientations are supported.
- **Signing help:** the README explains the App Group WQ Files needs, why wildcard profiles (Feather and similar) can't provide one, and how to sign instead.

## Safer backups and restores

- **Backups are checked before they're used.** Each app backup records checksums of its contents. A backup that changed afterwards, or a safety backup that doesn't match, is refused instead of restored.
- **Faster safety copies.** Before a file is changed, WQ Files makes an instant copy-on-write clone where the storage allows it, and checks free space before copying large files.
- **Every change is backed up**, also for files in WQ Files' own folder.
- **A restore can't start while an earlier one still needs repairing**, so recovery data is never overwritten.

## Safer file changes

- **Links are never followed** when creating, deleting, renaming or cleaning, and they're shown as links rather than as the files they point to.
- **Copies stop if the source changes while it's being copied**, instead of producing a mixed copy.
- **After saving in the hex viewer,** the changed bytes are read back and checked.
- **The backup folders can't be edited by accident** in the file browser; only complete backups can be deleted, from their own actions.
- **Interrupted access requests are repaired at the next start.** WQ Files briefly redirects one of its own folders to get access to a container; if it was closed in that moment, the folder is put back.

## Fixed

- **Plist editor:** files created by NSKeyedArchiver no longer crash the editor. Old OpenStep plists and unknown formats open read-only.
- **Cache Cleaner:** sizes that couldn't be fully measured are marked instead of shown too small, and only fully measured apps can be cleaned. It now reminds you to close the apps first.
- **Hex viewer:** offsets are checked properly (hex or decimal, nothing past the end), and Find starts over when you search for something new.
- **App names:** the app database is read more carefully and refreshed when it changes, without rescanning in the background every few seconds.
- **Apps list:** a container scan that can't be fully confirmed keeps what it found instead of showing an empty list; the reason is in the Log.
- **Copy Identifier** copies the bundle ID.
- **Folder views** refresh outdated sizes and details.
- **Smoother:** plists, text, images and hex views are prepared in the background, and long lists are cached.
- **The app now requires iOS 27**, so it can't be installed on iOS versions where it doesn't work.

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `73fc5790e9b9bec968c0253627356436c17bb6465b412683eff2700764e6e633`
