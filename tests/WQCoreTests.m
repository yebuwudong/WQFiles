//
//  WQCoreTests.m
//  WQ Files regression tests
//

#import <Foundation/Foundation.h>
#import "WQCore.h"

static int failures;

#define WQCheck(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); \
        failures++; \
    } \
} while (0)

static void TestHexParsing(void)
{
    NSData *parsed = WQParseHex(@"de ad\tbe\nef", NO);
    const uint8_t expected[] = { 0xde, 0xad, 0xbe, 0xef };
    WQCheck([parsed isEqualToData:[NSData dataWithBytes:expected length:sizeof(expected)]]);
    WQCheck([WQParseHex(@"<01 aB>", YES) isEqualToData:WQParseHex(@"01ab", NO)]);
    WQCheck(WQParseHex(@"<01>", NO) == nil);
    WQCheck(WQParseHex(@"abc", NO) == nil);
    WQCheck(WQParseHex(@"00-ff", NO) == nil);
    WQCheck(WQParseHex(@"００", NO) == nil);  // full-width digits are not ASCII hex
    WQCheck(WQParseHex(@" \n\t", NO).length == 0);
    WQCheck([WQParseHex(@"\u2003de\u00a0ad\vbe", NO)
             isEqualToData:WQParseHex(@"deadbe", NO)]);
    WQCheck(WQParseHex(@"aa z", NO) == nil);
    WQCheck(WQParseHex(@"0g", NO) == nil);
    WQCheck(WQParseHex(@"", YES).length == 0);
}

static void TestExactHexParsing(void)
{
    const uint8_t expected[] = { 0xde, 0xad, 0xbe, 0xef };
    NSData *four = [NSData dataWithBytes:expected length:sizeof(expected)];
    WQCheck([WQParseHexExactly(@"de ad be ef", 4) isEqualToData:four]);
    WQCheck([WQParseHexExactly(@" \tdeadbeef\n", 4) isEqualToData:four]);
    WQCheck(WQParseHexExactly(@"de ad be", 4) == nil);       // too few
    WQCheck(WQParseHexExactly(@"de ad be ef 00", 4) == nil); // count + 1 bytes
    WQCheck(WQParseHexExactly(@"de ad be e", 4) == nil);     // odd digit count
    WQCheck(WQParseHexExactly(@"<de ad be ef>", 4) == nil);  // no brackets in the hex editor
    WQCheck(WQParseHexExactly(@"de ad be zz", 4) == nil);
    WQCheck(WQParseHexExactly(@"", 0).length == 0 && WQParseHexExactly(@"", 0) != nil);
    WQCheck(WQParseHexExactly(@"00", 0) == nil);

    // At the textual bound the input is still parsed; one character more is
    // rejected before scanning, even though it is otherwise valid.
    NSUInteger limit = WQHexExactInputCharacterLimit(4);
    NSString *atLimit = [@"deadbeef" stringByPaddingToLength:limit withString:@" " startingAtIndex:0];
    WQCheck([WQParseHexExactly(atLimit, 4) isEqualToData:four]);
    NSString *overLimit = [atLimit stringByAppendingString:@" "];
    WQCheck(WQParseHexExactly(overLimit, 4) == nil);
    WQCheck(WQHexExactInputCharacterLimit(NSUIntegerMax) == NSUIntegerMax);

    // A huge valid paste for a 32-byte row is refused without being parsed.
    NSMutableString *huge = [NSMutableString new];
    for (NSUInteger i = 0; i < 4 * 1024 * 1024; i++) [huge appendString:@"ab"];
    NSDate *start = NSDate.date;
    WQCheck(WQParseHexExactly(huge, 32) == nil);
    WQCheck([NSDate.date timeIntervalSinceDate:start] < 0.5);
    // Within the textual bound, a valid count + 1 input stops at the extra byte.
    NSMutableString *oneMore = [NSMutableString new];
    for (NSUInteger i = 0; i < 33; i++) [oneMore appendString:@"ab "];
    WQCheck(oneMore.length <= WQHexExactInputCharacterLimit(32));
    WQCheck(WQParseHexExactly(oneMore, 32) == nil);
}

static void TestPatchRanges(void)
{
    WQCheck(WQPatchRangeValid(0, 0, 0));
    WQCheck(WQPatchRangeValid(8, 2, 10));
    WQCheck(WQPatchRangeValid(10, 0, 10));
    WQCheck(!WQPatchRangeValid(9, 2, 10));
    WQCheck(!WQPatchRangeValid(11, 0, 10));
    WQCheck(!WQPatchRangeValid(ULLONG_MAX - 1, 2, 10));  // must not wrap around
}

static void TestEditRevisions(void)
{
    WQEditState *state = [WQEditState new];
    WQCheck(!state.dirty && !state.saving && state.revision == 0);

    [state noteChange];
    WQCheck(state.dirty && state.revision == 1);
    NSUInteger saved = [state beginSave];
    WQCheck(state.saving && saved == 1);
    [state finishSave:YES revision:saved];
    WQCheck(!state.saving && !state.dirty);

    [state noteChange];
    saved = [state beginSave];
    [state noteChange];  // a newer revision must survive an older completion
    [state finishSave:YES revision:saved];
    WQCheck(!state.saving && state.dirty);

    saved = [state beginSave];
    [state finishSave:NO revision:saved];
    WQCheck(!state.saving && state.dirty);

    NSUInteger beforeDiscard = state.revision;
    [state discard];
    WQCheck(!state.dirty && state.revision == beforeDiscard + 1);

    [state noteChange];
    saved = [state beginSave];
    NSUInteger discardedRevision = state.revision;
    [state discard];
    [state finishSave:YES revision:saved];
    WQCheck(!state.saving && !state.dirty && state.revision == discardedRevision + 1);
}

static void TestRestorePlanning(void)
{
    NSDictionary *both = WQRestorePlan(YES, YES);
    WQCheck(both.count == 2 && [both[@"Documents"] boolValue] && [both[@"Library"] boolValue]);

    NSDictionary *documentsOnly = WQRestorePlan(YES, NO);
    WQCheck([documentsOnly[@"Documents"] boolValue]);
    WQCheck(![documentsOnly[@"Library"] boolValue]);  // absent Library must be purged

    NSDictionary *libraryOnly = WQRestorePlan(NO, YES);
    WQCheck(![libraryOnly[@"Documents"] boolValue]);
    WQCheck([libraryOnly[@"Library"] boolValue]);

    NSDictionary *neither = WQRestorePlan(NO, NO);
    WQCheck(neither.count == 2);
    WQCheck(![neither[@"Documents"] boolValue] && ![neither[@"Library"] boolValue]);
}

int main(void)
{
    @autoreleasepool {
        TestHexParsing();
        TestExactHexParsing();
        TestPatchRanges();
        TestEditRevisions();
        TestRestorePlanning();
        if (failures) {
            fprintf(stderr, "%d regression check(s) failed\n", failures);
            return 1;
        }
        puts("All WQCore regression tests passed.");
    }
    return 0;
}
