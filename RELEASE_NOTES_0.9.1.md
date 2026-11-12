> **Requires:** iOS 27, or iOS 26.0 – 26.7.2 (preliminary support). Tested on iOS 27.0.1, 27.2 and 26.7.1.
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.1

## Languages

- WQ Files is now available in **Simplified Chinese** ([#38](https://github.com/kolbicz/WQFiles/pull/38), thanks [iosrxwy](https://github.com/iosrxwy)), **Arabic** ([#39](https://github.com/kolbicz/WQFiles/issues/39), thanks [hfip](https://github.com/hfip)), **German**, **Italian** and **Spanish**.
- It follows the device language. **Settings → Language** on WQ Files' start screen picks another one; it's used from the next start.
- Arabic is shown right to left. File contents, the hex viewer, paths, SQL and the Log stay left to right.
- Corrections and new languages are welcome as pull requests: see [Translations](https://github.com/kolbicz/WQFiles#translations) in the README. German, Italian and Spanish are machine translations so far.

## New

- **Import as Backup…** (tap an app in Apps): turns a folder or ZIP with `Documents`/`Library` (a backup shared from another device, another tool's export) into a normal, verified backup of that app, ready to restore. Data that says it belongs to a different app asks first.
- **Keep Data Before Restore** (Settings, on by default): restoring an app or file backup first backs up what's there now, so a failed restore can be undone. Turn it off and that backup is deleted once the restore succeeded.
- **Media streams instead of copying:** audio and video play straight from the other app's folder, so large videos start right away. If a file can't be streamed, WQ Files copies it first as before.
- **Offloaded apps** ([#28](https://github.com/kolbicz/WQFiles/issues/28), iOS 27): Apps marks offloaded apps and has **Show: Installed / Offloaded**. The filters only appear when the state of nearly every app can be read; iOS 26 doesn't allow reading other apps' bundles.
- **App Bundles** (iOS 27): a new location with each installed app's bundle folder and its `.app`, labeled with the app's name. In Apps, long-press an app → **Open App Bundle**.

## Changed

- **Apps and the Cache Cleaner open instantly** the second time: they keep their list and rescan on their own after 10 minutes. Pull down to rescan any time.

## Fixed

- **Log:** reading app bundles stops after a few refusals instead of logging every app.

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic). Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `0e184168aa6f95fe9f824fb52f659edb6b0914089b4870adede27379091d96e5`
