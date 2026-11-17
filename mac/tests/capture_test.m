/* capture_test.m: end-to-end check of the capture, crop and pasteboard path, without
 * needing a hotkey or a person: it puts a known window on the screen (red over blue),
 * takes a frozen frame, crops a rect that crosses it, and checks the colours both in the
 * cropped CGImage and in the PNG that lands on the pasteboard.
 *
 *   ./mac/build.sh captest
 *
 * It verifies what a screenshot tool can get wrong silently: row order (flipped?), the
 * tile geometry for multi-display, and whether the copy is the pixels the user selected. */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "capture.h"
#include "common.h"
#include "output.h"
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

/* A window whose top half is red and bottom half blue, so a flipped row order is obvious. */
@interface TestView : NSView
@end

@implementation TestView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r
{
    (void)r;
    [[NSColor redColor] setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, self.bounds.size.height / 2));
    [[NSColor blueColor] setFill];
    NSRectFill(NSMakeRect(0, self.bounds.size.height / 2, self.bounds.size.width, self.bounds.size.height / 2));
}
@end

static uint32_t pixel_of_image(CGImageRef img, int x, int y)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    uint32_t *buf = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(cg, CGRectMake(0, 0, w, h), img);
    uint32_t p = (x >= 0 && y >= 0 && x < (int)w && y < (int)h) ? buf[(size_t)y * w + x] : 0;
    CGContextRelease(cg);
    free(buf);
    return p & 0xFFFFFF;
}

static bool is_red(uint32_t p) { return (p >> 16) > 0xE0 && ((p >> 8) & 0xFF) < 0x30 && (p & 0xFF) < 0x30; }
static bool is_blue(uint32_t p) { return (p & 0xFF) > 0xE0 && (p >> 16) < 0x30 && ((p >> 8) & 0xFF) < 0x30; }

static NSString *hex(uint32_t p) { return [NSString stringWithFormat:@"#%06X", p]; }

@interface Runner : NSObject
- (void)run;
- (void)finish;
@end

static NSWindow *g_win;
static Runner *g_runner;

@implementation Runner

- (void)run
{
    NSRect content = NSMakeRect(0, 0, 400, 300);
    g_win = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, content.size.width, content.size.height)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    g_win.contentView = [TestView new];
    g_win.level = NSFloatingWindowLevel;
    g_win.opaque = YES;
    g_win.backgroundColor = [NSColor redColor];
    [g_win orderFrontRegardless];

    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    NSRect f = g_win.frame;
    RECT win = {(LONG)f.origin.x, (LONG)(max_top - NSMaxY(f)), (LONG)(f.origin.x + f.size.width),
                (LONG)(max_top - f.origin.y)};
    printf("window at %ld,%ld %ldx%ld (global top-left)\n", (long)win.left, (long)win.top, (long)(win.right - win.left),
           (long)(win.bottom - win.top));

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      cap_take(^(SnipShot *shot) {
        CHECK(shot != NULL, "capture failed: %s", cap_last_error());
        if (!shot) {
            [self finish];
            return;
        }
        printf("shot %ld,%ld %ldx%ld, %d tiles, %.1f ms\n", (long)shot->vs.left, (long)shot->vs.top,
               (long)(shot->vs.right - shot->vs.left), (long)(shot->vs.bottom - shot->vs.top), shot->ntile, shot->ms);
        for (int i = 0; i < shot->ntile; i++)
            printf("  tile %d: %ld,%ld %ldx%ld  %dx%d px  scale %.2f\n", i, (long)shot->tile[i].rc.left,
                   (long)shot->tile[i].rc.top, (long)(shot->tile[i].rc.right - shot->tile[i].rc.left),
                   (long)(shot->tile[i].rc.bottom - shot->tile[i].rc.top), shot->tile[i].w, shot->tile[i].h,
                   (double)shot->tile[i].scale);

        /* crop a rect that starts inside the test window's top (red) area */
        RECT sel = {win.left + 20, win.top + 20, win.right - 20, win.bottom - 20};
        CGImageRef img = out_crop(shot, sel);
        CHECK(img != NULL, "crop failed");
        if (img) {
            int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
            uint32_t top = pixel_of_image(img, w / 2, 8);
            uint32_t bottom = pixel_of_image(img, w / 2, h - 8);
            printf("  crop %dx%d: top %s bottom %s\n", w, h, hex(top).UTF8String, hex(bottom).UTF8String);
            CHECK(is_red(top), "top of the crop should be red, got %s (row order?)", hex(top).UTF8String);
            CHECK(is_blue(bottom), "bottom of the crop should be blue, got %s", hex(bottom).UTF8String);
            CGImageRelease(img);
        }

        /* and the same through the pasteboard */
        CHECK(out_copy(shot, sel), "copy failed");
        NSData *png = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypePNG];
        CHECK(png.length > 0, "no PNG on the pasteboard");
        if (png.length) {
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
            CGImageRef back = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
            CHECK(back != NULL, "the pasteboard PNG does not decode");
            if (back) {
                uint32_t top = pixel_of_image(back, (int)CGImageGetWidth(back) / 2, 8);
                uint32_t bottom = pixel_of_image(back, (int)CGImageGetWidth(back) / 2, (int)CGImageGetHeight(back) - 8);
                printf("  pasteboard %zux%zu: top %s bottom %s (%zu bytes)\n", CGImageGetWidth(back),
                       CGImageGetHeight(back), hex(top).UTF8String, hex(bottom).UTF8String, (size_t)png.length);
                CHECK(is_red(top) && is_blue(bottom), "the pasted image is not the selection");
                CGImageRelease(back);
            }
            if (src)
                CFRelease(src);
        }

        /* windows under the middle of the test window: ours is excluded by design */
        RECT cand[8];
        int n = cap_windows_at((win.left + win.right) / 2, (win.top + win.bottom) / 2, cand, 8);
        printf("  windows under the test window: %d (own excluded)\n", n);

        cap_free(shot);
        [self finish];
      });
    });
}

- (void)finish
{
    [g_win close];
    printf("%d passed, %d failed\n", g_pass, g_fail);
    exit(g_fail ? 1 : 0);
}

@end

int main(void)
{
    @autoreleasepool {
        if (!cap_permission()) {
            printf("no screen recording permission for this process: nothing to test\n");
            return 3;
        }
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_runner = [Runner new];
        dispatch_async(dispatch_get_main_queue(), ^{
          [g_runner run];
        });
        [app run];
    }
    return 0;
}
