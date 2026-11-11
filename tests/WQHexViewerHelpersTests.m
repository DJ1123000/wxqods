#import "../WQHexViewerHelpers.h"

#include <stdio.h>

static void WQCheck(BOOL condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        _exit(1);
    }
}

int main(void)
{
    unsigned long long value = 0;
    WQCheck(WQHexParseOffset(@"0x1a2B", &value) && value == 0x1a2B, "hex offset");
    WQCheck(WQHexParseOffset(@"  42  ", &value) && value == 42, "trimmed decimal offset");
    WQCheck(WQHexParseOffset(@"18446744073709551615", &value) && value == ULLONG_MAX, "maximum offset");
    WQCheck(!WQHexParseOffset(@"", &value), "empty offset rejected");
    WQCheck(!WQHexParseOffset(@"   ", &value), "whitespace-only offset rejected");
    WQCheck(!WQHexParseOffset(@"-1", &value), "negative offset rejected");
    WQCheck(!WQHexParseOffset(@"+1", &value), "positive sign rejected");
    WQCheck(!WQHexParseOffset(@"123junk", &value), "trailing junk rejected");
    WQCheck(!WQHexParseOffset(@"0x", &value), "empty hexadecimal body rejected");
    WQCheck(!WQHexParseOffset(@"0xgg", &value), "invalid hexadecimal digit rejected");
    WQCheck(!WQHexParseOffset(@"18446744073709551616", &value), "decimal overflow rejected");
    WQCheck(!WQHexParseOffset(@"0x10000000000000000", &value), "hex overflow rejected");

    NSString *limit = [@"a" stringByPaddingToLength:WQHexSearchMaximumInputBytes
                                            withString:@"a"
                                       startingAtIndex:0];
    NSString *over = [limit stringByAppendingString:@"a"];
    WQCheck(WQHexSearchInputWithinLimit(limit), "maximum search input accepted");
    WQCheck(!WQHexSearchInputWithinLimit(over), "oversized search input rejected");
    WQCheck(WQHexSearchInputWithinLimit(@"hé"), "valid UTF-8 search input accepted");
    return 0;
}
