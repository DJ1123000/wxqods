> **Requires:** iOS 27, or iOS 26.0 – 26.7.2 (preliminary support). Tested on iOS 27.0.1, 27.2 and 26.7.1.
> **Needs:** a sideloading tool that keeps the App Group entitlement. WQ Files now tells you at launch if it's missing; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.8

## Apps show up in seconds

- **No more waiting for a scan.** Apps, Cache Cleaner, App Data and Extension Data now come from iOS's own app database, on every iOS version. The database is found once (usually within seconds) and remembered. Before, the first scan could take from a few minutes to most of an hour ([#11](https://github.com/kolbicz/WQFiles/issues/11), [#12](https://github.com/kolbicz/WQFiles/issues/12), [#16](https://github.com/kolbicz/WQFiles/issues/16), [#17](https://github.com/kolbicz/WQFiles/issues/17)).
- **Folders of uninstalled apps** that the database still remembers are left out, so they no longer show up as "refused access".
- **Scanning all files only when needed, and only if you agree.** Internal Daemons (and the app folders, if the database can't be read) still need a scan of every file. WQ Files now asks first, with the number of files and an estimated time, and shows a scan window with progress, time left, Hide and Stop. Later scans only check new files.

## New

- **Sorting** ([#14](https://github.com/kolbicz/WQFiles/issues/14)): sort folders by name, date modified, date created or size from the ••• menu; pick the same option again to reverse it. Folders on top is optional. Apps can be sorted by size or name.
- **A–Z sidebar** ([#20](https://github.com/kolbicz/WQFiles/issues/20)) for long lists sorted by name.
- **SQLite viewer** ([#21](https://github.com/kolbicz/WQFiles/issues/21)), read-only: tables and views with row counts, rows, single rows in full, SQL queries and CSV export. It works on a copy of the database, so the app's own files are never changed. Opens automatically for SQLite files, or via Open As.
- **Swipe to delete** in the file browser (left or right). It asks first, and files are backed up before they're deleted.
- **Signing check at launch.** If the sideloading tool removed the App Group, WQ Files says so right away and links to the signing help ([#15](https://github.com/kolbicz/WQFiles/issues/15)).
- **Version on the start screen**, next to "by kolbicz".

## Fixed

- **iOS 26:** app icons are still missing there. iOS 26 doesn't hand them out to WQ Files and doesn't let it read other apps' bundles, so apps show symbol tiles. Everything else works as on iOS 27, except System Data and System Groups.
- **Access checks** settle on the method that works on the device instead of switching back and forth.
- **The Log** shows which apps refused access and how the app database was read.

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `f640825776bd7620e04ee296647ed990a722124214153414e9796080ae140e03`
