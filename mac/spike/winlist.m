/* winlist.m: the on-screen windows of one process, to check that the status bar item
 * exists and where it is (Phase 1 acceptance). Not part of the app. */
#import <Cocoa/Cocoa.h>
#include <stdio.h>

int main(int argc, char *argv[])
{
    const char *who = argc > 1 ? argv[1] : "sniplite";
    @autoreleasepool {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        for (NSDictionary *w in (__bridge NSArray *)list) {
            NSString *owner = w[(id)kCGWindowOwnerName];
            if (![owner isEqualToString:@(who)])
                continue;
            CGRect b = CGRectZero;
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b);
            printf("layer=%-4d id=%-8d bounds=%.0f,%.0f %.0fx%.0f  name=%s\n",
                   [w[(id)kCGWindowLayer] intValue], [w[(id)kCGWindowNumber] intValue],
                   b.origin.x, b.origin.y, b.size.width, b.size.height,
                   [w[(id)kCGWindowName] UTF8String] ?: "");
        }
        CFRelease(list);
    }
    return 0;
}
