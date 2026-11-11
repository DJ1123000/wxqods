//
//  WQHexViewerHelpers.h
//  WQ Files
//
//  Small Foundation-portable validation helpers for the hex viewer.
//

#ifndef WQHexViewerHelpers_h
#define WQHexViewerHelpers_h

#import <Foundation/Foundation.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

// Keep both the search needle and the range-read overlap bounded before either
// can be materialized. This is a UTF-8 input limit, not a UI character limit.
static const NSUInteger WQHexSearchMaximumInputBytes = 1024UL * 1024UL;

static inline BOOL WQHexSearchInputWithinLimit(NSString *text)
{
    return text && [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= WQHexSearchMaximumInputBytes;
}

// Parses the complete trimmed input as an unsigned decimal or 0x-prefixed
// hexadecimal offset. The caller remains responsible for checking file range.
static inline BOOL WQHexParseOffset(NSString *text, unsigned long long *offset)
{
    if (!text || !offset) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return NO;

    BOOL hex = [trimmed hasPrefix:@"0x"] || [trimmed hasPrefix:@"0X"];
    NSString *digits = hex ? [trimmed substringFromIndex:2] : trimmed;
    if (!digits.length) return NO;

    unichar first = [digits characterAtIndex:0];
    if (first == '-' || first == '+') return NO;
    for (NSUInteger i = 0; i < digits.length; i++) {
        unichar c = [digits characterAtIndex:i];
        BOOL valid = c >= '0' && c <= '9';
        if (hex) valid = valid || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!valid) return NO;
    }

    const char *input = digits.UTF8String;
    NSUInteger inputBytes = [digits lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (!input || strlen(input) != inputBytes) return NO;

    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(input, &end, hex ? 16 : 10);
    if (errno == ERANGE || end == input || !end || *end != '\0') return NO;
    *offset = parsed;
    return YES;
}

#endif
