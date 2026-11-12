> **Requires:** iOS 27, or iOS 26.0 – 26.7.2 (preliminary support). Tested on iOS 27.0.1, 27.2 and 26.7.1.
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.2

## New

- **Edit SQLite databases** ([#21](https://github.com/kolbicz/WQFiles/issues/21)): open a database, tap **Edit**, then tap a value in a row to change it, swipe a row to delete it, or run any SQL. Changes go to WQ Files' copy until you tap **Save**.
  - **Force-quit the app before saving** (swipe it away in the app switcher). WQ Files can't tell whether it's running, and saving while it runs can corrupt its data.
  - Before writing, WQ Files checks the copy with SQLite's integrity check and refuses if the app changed its database since you opened it. The previous database goes to **Backups**.
  - Binary values and WITHOUT ROWID tables can be changed with SQL only. Files in Backups open read-only; with **Allow Deleting** off, rows can't be deleted by swiping.
- **Korean** ([#40](https://github.com/kolbicz/WQFiles/pull/40), thanks [hooray804](https://github.com/hooray804)).

## Fixed

- **Arabic:** corrections to the newer strings from [hfip](https://github.com/hfip) ([#39](https://github.com/kolbicz/WQFiles/issues/39)).
- **Empty app lists after an iOS update:** if WQ Files remembered an earlier scan of the app folders and none of them could be found anymore, it showed an empty list without saying why. It now checks again and reports the reason in the Log.
- **Cache Cleaner** says when no app folders were found, even if the scan was otherwise incomplete.

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean). Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `307274b67e82f68b140a3e2ed336c24c235a449a5a3f2017d232c76dc19942a5`
