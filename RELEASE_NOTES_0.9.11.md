> **Requires:** iOS 27, or iOS 26.0 – 26.7.2. Tested on iOS 27.0.1, 27.2.1, 26.7.1 and the 27.3 beta (confirmed by a user); see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.11

## New

- **Vietnamese** ([#62](https://github.com/kolbicz/WQFiles/pull/62)): WQ Files is now available in Vietnamese (Tiếng Việt). Pick it in **Settings → Language**.
- **Scans keep running and survive restarts** ([#61](https://github.com/kolbicz/WQFiles/pull/61)): Apps and Clean keep scanning when you switch tabs, and the last result is kept when WQ Files closes. An interrupted scan continues where it stopped. Use **Pause Scan** / **Resume Scan** to pause or resume one. A result older than 10 minutes refreshes when you open the screen.
- **Scan status in the tab bar:** a tab shows a spinner while its scan runs and a clock ◷ while it waits for another scan. On iPhone this is a gray badge.

## Changed

- **Full file scans ask before resuming:** an interrupted full scan only continues after you confirm it, and **Stop** discards its saved progress.
- **Fewer disk writes:** scan progress is saved every 20 seconds, without holding up the scan. Saved progress is deleted when a scan finishes, or after a week if it isn't resumed.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Resumable scans: hhh2210. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), romlayvn-93 (Vietnamese), buraakkcayir (Turkish review). Thanks to everyone who sent Logs and screenshots. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `b0ca5602762263b9db088f9df8536245fe178645aeb24587b8a2f818c9e996b8`
