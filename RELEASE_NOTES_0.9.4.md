> **Requires:** iOS 27, or iOS 26.0 – 26.7.2. Tested on iOS 27.0.1, 27.2.1 and 26.7.1.
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.4

## New

- **Delete folders with everything in them:** folders no longer have to be empty. WQ Files first says how many files (and how much) a folder holds, then copies every file into one backup and removes it, with progress and **Stop**. Restore them from **Recently Deleted**. App and system containers themselves, and the folders above them, stay protected.
- **Polish** and **Russian** (thanks to Reinascape, [#46](https://github.com/kolbicz/WQFiles/pull/46)), and **Portuguese (Brazil)**. Choose them under **Language** in WQ Files' Settings.
- **Filters in App Data, App Groups, Extension Data and Internal Daemons** ([#44](https://github.com/kolbicz/WQFiles/issues/44)): **Show** in the ⋯ menu: All, Apple, Other, and Backed Up in App Data. The ⋯ button is filled while a filter is on.
- **Version in the device strip:** the grey strip now shows the WQ Files version above the device and iOS line, so screenshots show which version is running.
- **Reset Access Cache** ([#42](https://github.com/kolbicz/WQFiles/issues/42)): if no app folder opens at startup, the check screen offers to repair the access cache. Another worse_query app that shares WQ Files' App Group (for example one signed with the same tool) can leave it in a state that blocks access. Nothing is deleted.

## Changed

- **Cache Cleaner:** when nothing needs cleaning, it says how many apps and extensions were checked instead of showing an empty list. Crash Logs that can't be measured no longer mark the whole scan as incomplete.

## Fixed

- **Backups failed on apps with "0 KB files"** ([#48](https://github.com/kolbicz/WQFiles/issues/48)): those are sockets and pipes, which can't be copied. Backups now leave them out (they hold no data).
- **Share as ZIP** of an app folder failed with "metadata.plist … no such file". WQ Files now zips with its own ZIP writer and leaves out files it isn't allowed to read. **Cancel** stops it while it runs.
- **App names:** WhatsApp, WA Business and other apps whose names start with an invisible character no longer show "�". Names with a zero-width joiner are shown instead of the bundle ID.

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian). Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `9b4fdcfe4d288025fd3c679143fd5be4fb8ea9db26fb6a09e6218b8bb966ff92`
