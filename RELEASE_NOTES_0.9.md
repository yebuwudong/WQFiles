> **Requires:** iOS 27, or iOS 26.0 – 26.7.2 (preliminary support). Tested on iOS 27.0.1, 27.2 and 26.7.1.
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9

## Work with several files at once

- **Select** (top right) in any folder to move, compress or delete several items together ([#9](https://github.com/kolbicz/WQFiles/issues/9)).
- **Move across apps:** pick the items, open the target folder in any app's data, tap **Move Here**. An item that's already there is never replaced.
- **ZIP:** **Compress** creates a ZIP next to the items; long-press a .zip and pick **Extract** to unpack it into a new folder. Entries that would land outside that folder, encrypted ZIPs and symbolic links are refused or left out.
- **Import several files at once, or a whole folder** with everything inside, from the ••• menu ([#23](https://github.com/kolbicz/WQFiles/issues/23)). If a name is taken, the import gets a number ("Name 2") instead of replacing anything.

## New

- **Syntax highlighting** ([#34](https://github.com/kolbicz/WQFiles/issues/34)): code and data files are colored in the text viewer and while editing: XML/plist, JSON, YAML, INI/TOML, CSS, SQL, Markdown, C/Objective-C, Swift, JavaScript/TypeScript, Java/Kotlin, Go, Rust, Python, shell, Ruby and Lua. Files without an extension are recognized by a `#!` line or XML/JSON content. Files over 1 MB stay plain.
- **Media player** ([#25](https://github.com/kolbicz/WQFiles/issues/25), [#29](https://github.com/kolbicz/WQFiles/issues/29)): audio and video (mp3, m4a, wav, flac, mp4, mov…) play in the system player, or use **Open As → Media Player**. The file is copied to WQ Files' temporary folder first, so very large videos take a moment to start.
- **Apps filter** ([#28](https://github.com/kolbicz/WQFiles/issues/28)): the button at the top right of Apps has **Show: All / Apple / Other / Backed Up** next to the sort options.
- **Bundle IDs** ([#27](https://github.com/kolbicz/WQFiles/issues/27)):
  - App Data and the other container lists show the bundle ID under the app name instead of the folder's UUID.
  - Long-press an app in Apps for **Copy Bundle ID**, **Copy Container Path** and **Open Data Folder**.
- **Restore from App Backups:** long-press an app in **App Backups** → **Restore Backup…** opens Apps and offers that app's backups. Restoring still needs the app installed.
- **Settings** on the start screen:
  - **Allow Deleting** ([#32](https://github.com/kolbicz/WQFiles/issues/32)), on by default. Turn it off and nothing can be deleted: Delete and swipe to delete disappear in folders and backups, Clear Data in Apps, and the Cache Cleaner won't clean. Saving, moving and restoring still work.
  - **Show Item Counts** ([#35](https://github.com/kolbicz/WQFiles/issues/35)), off by default. Folders show how many items they hold. Every subfolder has to be listed for this, which slows down folders with many subfolders, so the counts load after the list appears.

## Changed

- **Swipe left to delete** ([#36](https://github.com/kolbicz/WQFiles/issues/36)); swiping right no longer deletes.

## Fixed

- **iOS 26.5: Apps showed only a few apps** ([#37](https://github.com/kolbicz/WQFiles/issues/37)). iOS 26.5 stores the app database slightly differently from 26.7, so it was read wrong: only a few apps, with garbled names. WQ Files now knows the 26.5 layout. If an app database still can't be read properly, WQ Files no longer trusts it and offers the full scan instead.
- **Deleting locked files** ([#8](https://github.com/kolbicz/WQFiles/issues/8)): items with the "locked" flag (immutable or append-only) failed with "Operation not permitted". WQ Files now clears the flag and retries.
- **No App Group** ([#31](https://github.com/kolbicz/WQFiles/issues/31)): when the signing tool removed the App Group, WQ Files offered a long file scan that couldn't help. It now skips it and says the app needs re-signing.
- **Log:**
  - The app database summary appears once instead of twice.
  - A missing container identifier is reported once per folder.
  - Failed deletes record the item's flags, owner and permissions.

## Install

- The README has **Add AltSource** and **Download .ipa** buttons ([#24](https://github.com/kolbicz/WQFiles/issues/24)). The first adds the source to AltStore, SideStore, LiveContainer and others via AltDirect.
- **Sideloadly doesn't add the App Group** WQ Files needs ([#33](https://github.com/kolbicz/WQFiles/issues/33)). Use AltStore, SideStore or [Impactor](https://github.com/claration/impactor) (macOS, Windows, Linux; confirmed with a paid developer account) instead; the signing warning in the app now says so too.

## Credit

Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `aa45a13993d1b9ef52caf8ad6cb84b373d4289e955c23a11c46089d452721cc7`
