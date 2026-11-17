/* pin_test.m: the pin windows without a screen recording permission.
 *
 * It creates pins with synthetic images, then checks the window list of this process:
 * one window of the image's size at the requested place, hidden and shown again by the
 * "hide all pins" toggle, removed by close-all, and a clipboard image pinned through the
 * same path the hotkey uses. No capture, no TCC, no interaction.
 *
 *   ./mac/build.sh pintest */
#import <Cocoa/Cocoa.h>

#include <stdio.h>
#include <string.h>

#include "common.h"
#include "pin.h"
#include "plat.h"

static int g_pass, g_fail;

#define CHECK(cond, ...)                                                                    \
    do {                                                                                    \
        if (cond) {                                                                         \
            g_pass++;                                                                       \
        } else {                                                                            \
            g_fail++;                                                                       \
            printf("FAIL %s:%d  ", __FILE__, __LINE__);                                     \
            printf(__VA_ARGS__);                                                            \
            printf("\n");                                                                   \
        }                                                                                   \
    } while (0)

static CGImageRef solid_image(int w, int h, uint32_t rgb)
{
    uint32_t *px = calloc((size_t)w * (size_t)h, 4);
    for (int i = 0; i < w * h; i++)
        px[i] = 0xFF000000u | rgb;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(px, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGImageRef img = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    free(px);
    return img;
}

/* The pin window of a 100x80 image: same size, visible, at the requested y. */
static NSWindow *find_pin_window(int w, int h)
{
    for (NSWindow *win in [NSApp windows]) {
        if (![win isKindOfClass:NSWindow.class])
            continue;
        NSSize s = win.frame.size;
        if (fabs(s.width - w) < 1.5 && fabs(s.height - h) < 1.5)
            return win;
    }
    return nil;
}

@interface Runner : NSObject
- (void)run;
- (void)finish;
@end

@implementation Runner

- (void)run
{
    CGImageRef red = solid_image(100, 80, 0xE53935);
    pin_create(red, 300, 300);
    CGImageRelease(red);
    CHECK(pin_count() == 1, "pin_count is %d after one pin", pin_count());

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSWindow *win = find_pin_window(100, 80);
      CHECK(win != nil, "no pin window of 100x80");
      CHECK(win.isVisible, "the pin window is not visible");
      /* the window must actually paint its image, not just exist */
      NSView *view = win.contentView;
      NSBitmapImageRep *pinRep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
      [view cacheDisplayInRect:view.bounds toBitmapImageRep:pinRep];
      NSColor *c = [pinRep colorAtX:pinRep.pixelsWide / 2 y:pinRep.pixelsHigh / 2];
      NSColor *rgb = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      CHECK(rgb && rgb.redComponent > 0.7 && rgb.greenComponent < 0.3,
            "the pin view painted (%.2f, %.2f, %.2f), expected red", rgb.redComponent, rgb.greenComponent,
            rgb.blueComponent);
      if (win) {
          CGFloat max_top = 0;
          for (NSScreen *s in [NSScreen screens])
              max_top = MAX(max_top, NSMaxY(s.frame));
          double expectedY = max_top - 300 - 80;
          CHECK(fabs(win.frame.origin.y - expectedY) < 2, "the pin is at y %.0f, expected %.0f",
                win.frame.origin.y, expectedY);
      }

      pin_toggle_all();
      CHECK(pin_all_hidden(), "the hide toggle did not report hidden");
      CHECK(win && !win.isVisible, "the pin is still visible after hiding it");
      pin_toggle_all();
      CHECK(!pin_all_hidden() && win && win.isVisible, "the pin did not come back");

      /* clipboard path: a PNG on the pasteboard becomes a pin */
      CGImageRef blue = solid_image(40, 30, 0x1E88E5);
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:blue];
      CGImageRelease(blue);
      NSPasteboard *pb = [NSPasteboard generalPasteboard];
      [pb clearContents];
      [pb setData:[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
      CHECK(pin_from_clipboard(), "pin_from_clipboard failed on a PNG");
      CHECK(pin_count() == 2, "pin_count is %d after the clipboard pin", pin_count());

      /* and text becomes a pin too */
      [pb clearContents];
      [pb setString:@"sniplite" forType:NSPasteboardTypeString];
      CHECK(pin_from_clipboard(), "pin_from_clipboard failed on text");
      CHECK(pin_count() == 3, "pin_count is %d after the text pin", pin_count());

      pin_close_all();
      CHECK(pin_count() == 0, "close all left %d pins", pin_count());
      [self finish];
    });
}

- (void)finish
{
    printf("%d passed, %d failed\n", g_pass, g_fail);
    exit(g_fail ? 1 : 0);
}

@end

int main(void)
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Runner *r = [Runner new];
        dispatch_async(dispatch_get_main_queue(), ^{
          [r run];
        });
        [app run];
    }
    return 0;
}