/* long_test.m: the long screenshot from end to end, with a window that scrolls itself.
 *
 * A window shows a tall strip of one-colour rows and moves it up a few pixels every
 * 50 ms, standing in for a page the user scrolls. The long screenshot is started on that
 * window, runs two seconds, and the canvas it copied must be the strip: every row of it
 * the colour of the source row at the same index.
 *
 *   ./mac/build.sh longtest
 *
 * It puts windows on the screen for a few seconds and needs the screen recording
 * permission (screen capture); no keyboard or mouse is involved. */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "capture.h"
#include "common.h"
#include "longscreen.h"
#include "plat.h"

static int g_pass, g_fail;
#define CHECK(cond, ...)                                                                     \
    do {                                                                                     \
        if (cond) {                                                                          \
            g_pass++;                                                                        \
        } else {                                                                             \
            g_fail++;                                                                        \
            printf("FAIL %s:%d  ", __FILE__, __LINE__);                                      \
            printf(__VA_ARGS__);                                                             \
            printf("\n");                                                                    \
        }                                                                                    \
    } while (0)

static const int W = 400, H = 300, PAGE = 2000;

static uint32_t row_color(int r)
{
    return (uint32_t)(((r * 37) % 256) << 16 | ((r * 91) % 256) << 8 | ((r * 13) % 256));
}

@interface Scroller : NSView
@end

static int g_off;
static NSTimer *g_scrollTimer;

@implementation Scroller
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r
{
    (void)r;
    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
    for (int y = 0; y < H; y++) {
        int src = g_off + y;
        if (src < 0 || src >= PAGE)
            continue;
        uint32_t c = row_color(src);
        CGContextSetFillColorWithColor(cg, [NSColor colorWithSRGBRed:(CGFloat)((c >> 16) & 0xFF) / 255.0
                                                               green:(CGFloat)((c >> 8) & 0xFF) / 255.0
                                                                blue:(CGFloat)(c & 0xFF) / 255.0
                                                               alpha:1]
                                          .CGColor);
        CGContextFillRect(cg, CGRectMake(0, y, W, 1));
    }
}
@end

static uint32_t pixel_at(CGImageRef img, int x, int y)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    uint32_t *buf = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(cg, CGRectMake(0, 0, w, h), img);
    uint32_t p = (x >= 0 && y >= 0 && x < (int)w && y < (int)h) ? buf[(size_t)y * w + x] & 0xFFFFFF : 0;
    CGContextRelease(cg);
    free(buf);
    return p;
}

static bool close_color(uint32_t a, uint32_t b)
{
    int dr = (int)((a >> 16) & 0xFF) - (int)((b >> 16) & 0xFF);
    int dg = (int)((a >> 8) & 0xFF) - (int)((b >> 8) & 0xFF);
    int db = (int)(a & 0xFF) - (int)(b & 0xFF);
    return abs(dr) <= 12 && abs(dg) <= 12 && abs(db) <= 12;
}

@interface Runner : NSObject
@end

static NSWindow *g_win;
static Runner *g_runner;

@implementation Runner

- (void)run
{
    g_win = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 400, W, H)
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    g_win.contentView = [Scroller new];
    g_win.backgroundColor = [NSColor blackColor];
    g_win.level = NSFloatingWindowLevel;
    [g_win orderFrontRegardless];

    g_scrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                     target:self
                                                   selector:@selector(scroll:)
                                                   userInfo:nil
                                                    repeats:YES];

    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    NSRect f = g_win.frame;
    RECT rc = {(LONG)f.origin.x, (LONG)(max_top - NSMaxY(f)), (LONG)(f.origin.x + f.size.width),
               (LONG)(max_top - f.origin.y)};

    /* wait a moment, then check the capture itself: the window's pixels, in order */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [g_scrollTimer invalidate];
      g_scrollTimer = nil;
      int off = g_off;
      cap_sample_rect(rc, ^(uint32_t *px, int w, int h) {
        printf("calibration: %dx%d at page row %d\n", w, h, off);
        CHECK(px && w == W && h == H, "the sample is %dx%d, expected %dx%d", w, h, W, H);
        if (px && w == W) {
            int bad = 0;
            for (int y = 0; y < H && !bad; y++)
                if (!close_color(px[(size_t)y * w + w / 2] & 0xFFFFFF, row_color(off + y)))
                    bad = y + 1;
            CHECK(!bad, "sample row %d is not the page's row %d", bad - 1, off + bad - 1);
            free(px);
        }
        /* from here on the page scrolls and the long screenshot has to follow it */
        g_off = 0;
        g_scrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                         target:g_runner
                                                       selector:@selector(scroll:)
                                                       userInfo:nil
                                                        repeats:YES];
        CHECK(long_begin(rc), "long_begin failed");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          [g_scrollTimer invalidate];
          g_scrollTimer = nil;
          printf("scrolled %d px\n", g_off);
          long_finish(true, false, false);
          NSData *png = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypePNG];
          CHECK(png.length > 0, "no PNG on the pasteboard");
          if (png.length) {
              CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
              CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
              CHECK(img != NULL, "the pasted PNG does not decode");
              if (img) {
                  int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
                  printf("canvas %dx%d\n", w, h);
                  CHECK(w == W, "canvas width %d, expected %d", w, W);
                  CHECK(h > H + 40, "the canvas did not grow: %d rows", h);
                  int delta = -1;
                  for (int d = 0; d < 60 && delta < 0; d++) {
                      int bad = 0;
                      for (int y = 0; y < h - 2 && !bad; y++)
                          if (!close_color(pixel_at(img, w / 2, y), row_color(d + y)))
                              bad = 1;
                      if (!bad)
                          delta = d;
                  }
                  CHECK(delta >= 0, "the canvas matches no part of the page");
                  printf("canvas starts at page row %d\n", delta);
                  int bad = 0;
                  for (int y = 4; y < h - 4 && !bad && delta >= 0; y++) {
                      uint32_t want = row_color(delta + y);
                      uint32_t got = pixel_at(img, w / 2, y);
                      if (!close_color(got, want)) {
                          printf("row %d: #%06X, expected #%06X (page row %d)\n", y, got, want, delta + y);
                          bad = y;
                      }
                  }
                  CHECK(!bad, "canvas row %d is not the page's row", bad);
                  CGImageRelease(img);
              }
              if (src)
                  CFRelease(src);
          }
          [g_win close];
          printf("%d passed, %d failed\n", g_pass, g_fail);
          fflush(stdout);
          exit(g_fail ? 1 : 0);
        });
      });
    });
}

- (void)scroll:(NSTimer *)t
{
    (void)t;
    g_off += 4;
    if (g_off > PAGE - H)
        g_off = PAGE - H;
    [g_win.contentView setNeedsDisplay:YES];
}

@end

int main(void)
{
    @autoreleasepool {
        if (!cap_permission()) {
            printf("no screen recording permission: nothing to test\n");
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
