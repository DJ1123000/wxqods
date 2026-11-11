> **Requires:** iOS 27, or iOS 26.0 – 26.7.2 (preliminary support). Tested on iOS 27.0.1, 27.2 and 26.7.1.
> **Needs:** a sideloading tool that keeps the App Group entitlement. If the Log says "No App Group", re-sign with one that does; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.7

## iOS 27.2: apps show their names

On iOS 27.2, apps and extensions showed up as long IDs without names, and the Cache Cleaner couldn't clean anything ([#1](https://github.com/kolbicz/WQFiles/issues/1), [#7](https://github.com/kolbicz/WQFiles/issues/7), [#8](https://github.com/kolbicz/WQFiles/issues/8), [#9](https://github.com/kolbicz/WQFiles/issues/9)). iOS 27.2 stores the app database differently; WQ Files now reads it, and finds out which apps the containers belong to from it.

## Preliminary iOS 26 support (26.0 – 26.7.2)

- **Apps, Extension Data and App Groups are listed from the app database.** A full scan would take most of an hour on iOS 26; the database is found once and remembered.
- **Internal Daemons** need a full scan on iOS 26. The first one takes long and shows the time left; later ones only check new files.
- **Icons** are missing on iOS 26: iOS doesn't hand them out to WQ Files there, so apps show symbol tiles.
- System Data and System Groups can't be reached on iOS 26 and are hidden.

## Faster scans

- **Only the first scan is slow.** Found containers are remembered; later scans check only files created since, with a full scan once a week.
- **Leaving a screen no longer throws a scan away.** It keeps running, and the next screen uses the result.
- **Folder lists show progress** while containers are read ("Reading containers… 120 of 360").

## New

- **Swipe to delete.** Swipe a row left or right in the file browser to delete it. It asks first, like the long-press menu, and files are backed up before they're deleted.

## Fixed

- **Access that didn't work is noticed.** On some setups iOS handed out access that didn't actually open the folders, so nothing had a name. WQ Files now checks every access and falls back to the other access method when needed.
- **The Log says more:** how long a scan took, which apps refused access, and how the app database was read.
- **A cancelled scan** is no longer reported as "no containers found".

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Thanks to everyone who sent Logs from iOS 26 and 27.2. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `a02167446b03bca24b688bd33d57b4bec967f637e854084aba60e808df4fdaa3`
