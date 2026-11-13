//
//  WQLocalizationTests.m
//  WQ Files regression tests
//
//  Runs against the real <lang>.lproj tables (run_localization_tests.sh copies
//  them next to the binary and passes -AppleLanguages). Checks that keys are
//  localized exactly once and that WQVerbatim text is never looked up.
//

#import <Foundation/Foundation.h>
#import "WQLocalization.h"

static int failures;

#define WQCheck(...) do { const BOOL wq_ok = (__VA_ARGS__); \
    if (!wq_ok) { \
        fprintf(stderr, "FAIL [%s] %s:%d: %s\n", language.UTF8String, __func__, __LINE__, #__VA_ARGS__); \
        failures++; \
    } \
} while (0)

static void TestVerbatimMarker(NSString *language)
{
    WQCheck(WQVerbatim(nil) == nil);
    WQCheck(WQLocalizedNullable(nil) == nil);
    for (NSString *raw in @[ @"Delete", @"Files", @"Date", @"Data", @"Cancel", @"OK" ]) {
        NSString *verbatim = WQVerbatim(raw);
        WQCheck(WQIsVerbatim(verbatim) && !WQIsVerbatim(raw));
        WQCheck([verbatim isEqualToString:raw] && [raw isEqualToString:verbatim] && verbatim.hash == raw.hash);
        WQCheck([WQLocalized(verbatim) isEqualToString:raw]);
        WQCheck([WQLocalizedNullable(verbatim) isEqualToString:raw]);
        WQCheck(WQIsVerbatim([verbatim copy]));
        WQCheck(WQVerbatim(verbatim) == verbatim);
        WQCheck([[NSString stringWithFormat:@"<%@>", verbatim] isEqualToString:[NSString stringWithFormat:@"<%@>", raw]]);
    }
    WQCheck([WQLocalizedFormat(WQVerbatim(@"Delete %@"), @"x") isEqualToString:@"Delete x"]);
}

static void TestTypeNamesLocalizeOnce(NSString *language)
{
    // The plist Add sheet passes the type key to the key-taking action helper,
    // and embeds already-localized names as WQVerbatim.
    NSString *date = WQLocalized(@"Date"), *data = WQLocalized(@"Data");
    WQCheck(![date isEqualToString:data]);
    WQCheck([WQLocalized(WQVerbatim(date)) isEqualToString:date]);
    WQCheck(![WQLocalized(WQVerbatim(date)) isEqualToString:WQLocalized(WQVerbatim(data))]);
    if ([@[ @"it", @"pl", @"pt-BR" ] containsObject:language]) {
        // The hazard WQVerbatim prevents: a second lookup turns Date into Data.
        WQCheck([date isEqualToString:@"Data"]);
        WQCheck([WQLocalized(date) isEqualToString:data]);
    }
}

static void TestRawTextIsNotTranslated(NSString *language)
{
    if (![language isEqualToString:@"en"]) WQCheck(![WQLocalized(@"Delete") isEqualToString:@"Delete"]);
    // A plist key, SQLite column or app named "Delete" stays "Delete".
    WQCheck([WQLocalized(WQVerbatim(@"Delete")) isEqualToString:@"Delete"]);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <language> -AppleLanguages '(<language>)'\n", argv[0]); return 2; }
        NSString *language = @(argv[1]);
        NSString *active = NSBundle.mainBundle.preferredLocalizations.firstObject;
        WQCheck([active isEqualToString:language]);   // the tables are really in use
        TestVerbatimMarker(language);
        TestTypeNamesLocalizeOnce(language);
        TestRawTextIsNotTranslated(language);
        if (failures) {
            fprintf(stderr, "%d localization runtime check(s) failed for %s\n", failures, argv[1]);
            return 1;
        }
        printf("Localization runtime checks passed for %s.\n", argv[1]);
    }
    return 0;
}
