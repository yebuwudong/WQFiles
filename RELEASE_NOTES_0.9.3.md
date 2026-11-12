> **Requires:** iOS 27, or iOS 26.0 – 26.7.2 (preliminary support). Tested on iOS 27.0.1, 27.2.1 and 26.7.1.
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.3

## New

- **Startup check:** while the start screen is up, WQ Files checks in the background that everything it depends on works: the App Group, finding other apps' folders, its sandbox access (a sample of those folders must really open) and the app database (names). If a new iOS version or a signing problem breaks something essential, WQ Files now stops with what failed, with **Try Again**, **Log** and **Continue Anyway**, instead of showing empty or wrong lists. Problems that leave it partly usable are shown once as a notice.
- **Recently Deleted** (under Backups on the start screen, [#41](https://github.com/kolbicz/WQFiles/issues/41)): files WQ Files deleted, newest first, from their copies in Backups. Tap to view, **Restore** puts a file back where it was (missing folders are created, nothing is replaced), **Delete Permanently** or **Delete All** removes them from Backups.

## Changed

- **Cache Cleaner:** the bar shows the scan's progress while scanning, and the total counts up during the first scan.
- **App Bundles** and **Open App Bundle** only appear where iOS lets WQ Files open those folders; iOS 26 and 27.0.1 don't.
- **Offloaded apps:** Apple's built-in apps count as installed, and the Installed/Offloaded filters only appear when the state of nearly every app can be read. On the iOS versions tested so far iOS refuses to show other apps' bundles, so the filters usually stay hidden.

## Fixed

- **Log:** reading app bundles no longer adds a line per app.

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean). Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `7aa60c63dc1c51928ab0d0d304dd56f07204a132b7833cc50b5ab3d4b3b0b321`
