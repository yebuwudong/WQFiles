> **Requires:** iOS 27, or iOS 26.0 – 26.7.2. Tested on iOS 27.0.1, 27.2.1, 26.7.1 and the 27.3 beta (confirmed by a user); see [Tested devices](https://github.com/kolbicz/WQFiles#tested-devices).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.9

## New

- **Plain Background** ([#56](https://github.com/kolbicz/WQFiles/issues/56)): **Settings → Plain Background** replaces the colored backdrop of the new design with plain black (white in light mode). It applies right away.
- **Dark and tinted app icon** ([#47](https://github.com/kolbicz/WQFiles/issues/47)): the WQ Files icon now has its own dark and tinted versions for the iOS 18+ Home Screen styles.

## Fixes

- **App Groups show their names on iOS 27.2 and later** ([#59](https://github.com/kolbicz/WQFiles/pull/59)): some or all App Groups showed only a UUID, because iOS 27.2 removed the attribute WQ Files read the name from. WQ Files now reads its replacement and, as a second source, the group ids in each app's record in the LaunchServices database. Both give exact names, no guessing.
- **App Group icons:** groups such as `group.net.whatsapp.WhatsApp.shared` now look up the icon of the app inside the id (`net.whatsapp.WhatsApp`) instead of ids that are never apps.
- **Files you can't open are dimmed** ([#57](https://github.com/kolbicz/WQFiles/issues/57)): files and folders whose owner and permissions keep WQ Files out (usually root-only) are shown dimmed with a lock and "No access". Tapping one explains who owns it instead of opening an empty viewer.
- **iOS 18 and older** ([#58](https://github.com/kolbicz/WQFiles/issues/58)): some sideloading tools install WQ Files there despite the iOS 26 minimum. It now shows a notice that it needs iOS 26 or 27 (and points to Cyanide for iOS 17 and 18) instead of scanning for minutes and failing.

## Changed

- **Translations** for the new texts in all languages.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), buraakkcayir (Turkish review). Thanks to VaslD for the App Group report and analysis, and to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `20f0bf846e018775779e305a5b390f3ac495a42d60ecfdd039823811777a139b`
