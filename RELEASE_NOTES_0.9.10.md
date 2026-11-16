> **Requires:** iOS 27, or iOS 26.0 – 26.7.2. Tested on iOS 27.0.1, 27.2.1, 26.7.1 and the 27.3 beta (confirmed by a user); see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.10

## Fixes

- **Missing apps:** some installed apps didn't appear in Apps, App Data or Extension Data (on iOS 26.5, for example UC Browser; 279 instead of 295 apps). Folders that the app database names but couldn't be paired with an app were left out. They are listed now and get their name from the folder itself.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), buraakkcayir (Turkish review). Thanks to everyone who sent Logs and screenshots. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `1df859a827e589a9a1668b3bd3e3966b69eedf3e9a56a84e6f041183295adda9`
