/* wlayers.m: windows on a given CGWindow layer, any owner (Phase 1: where the status
 * item window actually is). Not part of the app. */
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
    int layer = argc > 1 ? atoi(argv[1]) : 25;
    @autoreleasepool {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        for (NSDictionary *w in (__bridge NSArray *)list) {
            if ([w[(id)kCGWindowLayer] intValue] != layer)
                continue;
            CGRect b = CGRectZero;
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b);
            printf("%-20s id=%-8d %.0f,%.0f %.0fx%.0f\n", [w[(id)kCGWindowOwnerName] UTF8String] ?: "?",
                   [w[(id)kCGWindowNumber] intValue], b.origin.x, b.origin.y, b.size.width, b.size.height);
        }
        CFRelease(list);
    }
    return 0;
}
