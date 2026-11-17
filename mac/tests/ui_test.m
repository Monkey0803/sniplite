/* ui_test.m: the overlay's interaction paths, without a person.
 *
 * The overlay is built over a synthetic frame (no screen capture, no permission), then the
 * same handlers the mouse and the keyboard call are driven with synthetic NSEvents:
 * drag a selection, click the rectangle tool in the toolbar, drag a rectangle, undo and
 * redo it, press Return, and check that the pasteboard holds the annotated selection.
 *
 *   ./mac/build.sh uitest
 *
 * What it covers: selection geometry, the eight handles, nudging and moving the selection,
 * toolbar hit testing, a palette colour, the text tool, annotation creation and undo, the
 * copy path with annotations, and Esc/Return handling. Launched from Finder (uitest-app) it
 * also checks that the app takes the focus and that the overlay view is the first responder.
 * What it cannot cover: the input method itself and the screen recording permission (both
 * need a person). */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "annotate.h"
#include "capture.h"
#include "common.h"
#include "overlay.h"
#include "ov_layout.inc"
#include "pin.h"
#include "pin.h"
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

static SnipShot *make_shot(void)
{
    SnipShot *s = calloc(1, sizeof *s);
    s->ntile = 1;
    s->tile = calloc(1, sizeof(SnipTile));
    s->vs = (RECT){0, 0, 700, 500};
    s->tile[0].rc = s->vs;
    s->tile[0].scale = 1;
    s->tile[0].w = 700;
    s->tile[0].h = 500;
    s->tile[0].px = calloc(700 * 500, 4);
    for (int i = 0; i < 700 * 500; i++)
        s->tile[0].px[i] = 0xFFFFFFFFu; /* white */
    for (int y = 100; y < 110; y++) /* green, at the selection's top-left corner */
        for (int x = 100; x < 110; x++)
            s->tile[0].px[y * 700 + x] = 0xFF00C000u;
    return s;
}

static void free_shot(SnipShot *s)
{
    free(s->tile[0].px);
    free(s->tile);
    free(s);
}

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

static bool close_color(uint32_t a, uint32_t b, int tol)
{
    int dr = (int)((a >> 16) & 0xFF) - (int)((b >> 16) & 0xFF);
    int dg = (int)((a >> 8) & 0xFF) - (int)((b >> 8) & 0xFF);
    int db = (int)(a & 0xFF) - (int)(b & 0xFF);
    return abs(dr) <= tol && abs(dg) <= tol && abs(db) <= tol;
}

static bool any_near(CGImageRef img, int x0, int y0, int r, uint32_t want, int tol)
{
    for (int y = y0 - r; y <= y0 + r; y++)
        for (int x = x0 - r; x <= x0 + r; x++)
            if (close_color(pixel_at(img, x, y), want, tol))
                return true;
    return false;
}

static void drag(double x0, double y0, double x1, double y1)
{
    ov_test_mouse(1, x0, y0);
    ov_test_mouse(2, x1, y1);
    ov_test_mouse(3, x1, y1);
}

static SnipShot *g_shot;
static bool g_bundle;

static void finish(void)
{
    printf("DONE %d %d\n", g_pass, g_fail);
    fflush(stdout);
    exit(g_fail ? 1 : 0);
}

/* the interaction checks, with the overlay already showing */
static void run_checks(void)
{
    /* --- 1. a drag selects, the toolbar picks the rectangle tool, a drag annotates --- */
    drag(100, 100, 500, 400);
    RECT sel = ov_test_sel();
    printf("selection %ld,%ld %ldx%ld\n", (long)sel.left, (long)sel.top, (long)(sel.right - sel.left),
           (long)(sel.bottom - sel.top));
    /* rect_corners is inclusive, as on Windows: 100..500 is 401 pixels wide */
    CHECK(sel.left == 100 && sel.top == 100 && sel.right == 501 && sel.bottom == 401, "selection is %ld,%ld %ldx%ld",
          (long)sel.left, (long)sel.top, (long)(sel.right - sel.left), (long)(sel.bottom - sel.top));
    CHECK(ov_test_click_button(T_RECT), "the rectangle button is not in the toolbar");
    CHECK(ov_test_tool() == T_RECT, "clicking the rectangle button did not select it, tool %d", ov_test_tool());
    drag(150, 150, 350, 250);
    CHECK(ov_test_anno_count() == 1, "the drag made %d annotations", ov_test_anno_count());

    /* --- 2. Return copies the annotated selection and closes the overlay --- */
    ov_test_key(36, 0);
    CHECK(!ov_active(), "Return did not close the overlay");
    NSData *png = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypePNG];
    CHECK(png.length > 0, "no PNG on the pasteboard");
    if (png.length) {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
        CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        CHECK(img != NULL, "the pasted PNG does not decode");
        if (img) {
            printf("copied %zux%zu\n", CGImageGetWidth(img), CGImageGetHeight(img));
            CHECK(CGImageGetWidth(img) == 401 && CGImageGetHeight(img) == 301, "the copy is %zux%zu",
                  CGImageGetWidth(img), CGImageGetHeight(img));
            CHECK(any_near(img, 4, 4, 3, 0x00C000, 24), "the copy lost the frame's top-left corner");
            CHECK(any_near(img, 54, 54, 6, 0xE53935, 40), "the copy has no rectangle annotation");
            CGImageRelease(img);
        }
        if (src)
            CFRelease(src);
    }

    /* --- 3. undo and redo through the keyboard --- */
    CHECK(ov_test_begin(g_shot), "second ov_test_begin failed");
    drag(50, 50, 650, 450);
    CHECK(ov_test_click_button(T_RECT), "the rectangle button is missing on the second run");
    drag(120, 120, 220, 180);
    drag(300, 200, 420, 300);
    CHECK(ov_test_anno_count() == 2, "two drags made %d annotations", ov_test_anno_count());
    ov_test_key(6, 1ul << 20); /* Cmd+Z */
    CHECK(ov_test_anno_count() == 1, "undo left %d annotations", ov_test_anno_count());
    ov_test_key(6, (1ul << 20) | (1ul << 17)); /* Shift+Cmd+Z */
    CHECK(ov_test_anno_count() == 2, "redo left %d annotations", ov_test_anno_count());

    /* --- 4. Esc drops the selection, then leaves without touching the pasteboard --- */
    NSData *before = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypePNG];
    ov_test_key(53, 0);
    ov_test_key(53, 0);
    CHECK(!ov_active(), "Esc did not close the overlay");
    NSData *after = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypePNG];
    CHECK(before.length == after.length, "Esc changed the pasteboard");

    /* --- 5. the eight handles, arrow nudging and moving the selection --- */
    CHECK(ov_test_begin(g_shot), "third ov_test_begin failed");
    drag(100, 100, 500, 400);
    double hx = 0, hy = 0;
    CHECK(ov_test_handle_point(5, &hx, &hy), "the south-east handle is missing"); /* 5 = SE */
    ov_test_mouse(1, hx, hy);
    ov_test_mouse(2, 540, 440);
    ov_test_mouse(3, 540, 440);
    RECT r = ov_test_sel();
    printf("after resizing the SE handle: %ld,%ld %ldx%ld\n", (long)r.left, (long)r.top,
           (long)(r.right - r.left), (long)(r.bottom - r.top));
    CHECK(r.left == 100 && r.top == 100 && r.right == 541 && r.bottom == 441,
          "the handle drag gave %ld,%ld %ldx%ld", (long)r.left, (long)r.top, (long)(r.right - r.left),
          (long)(r.bottom - r.top));

    ov_test_key(124, 0); /* right arrow nudges the selection by one point */
    r = ov_test_sel();
    CHECK(r.left == 101 && r.right == 542, "the arrow key gave %ld..%ld", (long)r.left, (long)r.right);

    drag(300, 300, 320, 330); /* no tool: dragging inside moves the selection */
    r = ov_test_sel();
    printf("after moving: %ld,%ld %ldx%ld\n", (long)r.left, (long)r.top, (long)(r.right - r.left),
           (long)(r.bottom - r.top));
    CHECK(r.left == 121 && r.top == 130 && r.right == 562 && r.bottom == 471,
          "moving the selection gave %ld,%ld %ldx%ld", (long)r.left, (long)r.top, (long)(r.right - r.left),
          (long)(r.bottom - r.top));
    ov_test_key(53, 0);
    ov_test_key(53, 0);
    CHECK(!ov_active(), "the overlay did not close after the move test");

    /* --- 6. a palette colour and the text tool --- */
    CHECK(ov_test_begin(g_shot), "fourth ov_test_begin failed");
    drag(100, 100, 600, 400);
    CHECK(ov_test_click_button(T_RECT), "the rectangle button is missing");
    CHECK(ov_test_click_palette(4), "the blue palette cell is missing"); /* 4 = blue 1E88E5 */
    drag(150, 150, 250, 220);
    CHECK(ov_test_click_button(T_TEXT), "the text button is missing");
    ov_test_mouse(1, 320, 300);
    ov_test_mouse(3, 320, 300);
    CHECK(ov_test_type("中文 abc"), "the text field did not take the text");
    CHECK(ov_test_anno_count() == 2, "the text tool made %d annotations", ov_test_anno_count());
    ov_test_key(36, 0);
    CHECK(!ov_active(), "Return did not close the overlay after the text");
    NSData *png2 = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypePNG];
    CHECK(png2.length > 0, "no PNG after the text test");
    if (png2.length) {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png2, NULL);
        CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        CHECK(img != NULL, "the PNG after the text does not decode");
        if (img) {
            printf("text run copied %zux%zu\n", CGImageGetWidth(img), CGImageGetHeight(img));
            CHECK(any_near(img, 54, 54, 6, 0x1E88E5, 40), "the palette colour did not reach the annotation");
            bool ink = false;
            for (int y = 190; y < 240 && !ink; y++)
                for (int x = 210; x < 340 && !ink; x++) {
                    uint32_t p = pixel_at(img, x, y);
                    if ((p >> 16) < 0xD0 || ((p >> 8) & 0xFF) < 0xD0 || (p & 0xFF) < 0xD0)
                        ink = true;
                }
            CHECK(ink, "the copied image has no text at 220,200");
            CGImageRelease(img);
        }
        if (src)
            CFRelease(src);
    }

    /* --- 7. the pin button: the annotated selection becomes a pinned panel --- */
    pin_close_all();
    CHECK(ov_test_begin(g_shot), "fifth ov_test_begin failed");
    drag(100, 100, 400, 300);
    CHECK(ov_test_click_button(T_RECT), "the rectangle button is missing before the pin");
    drag(150, 150, 250, 220);
    CHECK(ov_test_click_button(B_PIN), "the pin button is missing");
    CHECK(!ov_active(), "the pin button did not close the overlay");
    CHECK(pin_count() == 1, "the pin button made %d pins", pin_count());
    double pinW = 0, factor = pin_test_zoom_last(2.0, &pinW);
    printf("pin zoom: factor %.2f, width %.0f\n", factor, pinW);
    CHECK(factor > 1.5 && factor < 2.5, "zooming the pin changed nothing (factor %.2f)", factor);
    CHECK(pin_test_level_last() == (int)NSStatusWindowLevel, "the pin is not above the other windows (%d)",
          pin_test_level_last());
    pin_close_all();
    CHECK(pin_count() == 0, "closing all pins left %d", pin_count());
}


int main(void)
{
    @autoreleasepool {
        g_bundle = [[NSBundle mainBundle] bundleIdentifier] != nil;
        if (g_bundle) { /* launched with open: there is no stdout, so write the result */
            freopen("/tmp/sniplite-ui-result.txt", "w", stdout);
            setvbuf(stdout, NULL, _IOLBF, 0);
        }
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_shot = make_shot();

        dispatch_async(dispatch_get_main_queue(), ^{
          CHECK(ov_test_begin(g_shot), "ov_test_begin failed");
          if (!g_bundle) {
              run_checks();
              free_shot(g_shot);
              finish();
              return;
          }
          /* launched from Finder: this is where the keyboard focus matters */
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSWindow *key = [NSApp keyWindow];
            NSResponder *fr = key.firstResponder;
            printf("activation: active=%d keyWindow=%d firstResponder=%s\n", (int)NSApp.isActive, (int)(key != nil),
                   fr ? NSStringFromClass([fr class]).UTF8String : "nil");
            CHECK(NSApp.isActive, "the app did not become active when launched from Finder");
            CHECK(key != nil, "no key window after activation");
            CHECK(fr && [fr isKindOfClass:[NSView class]] && [(NSView *)fr window] == key,
                  "the overlay view is not the window's first responder");
            run_checks();
            free_shot(g_shot);
            finish();
          });
        });
        [app run];
    }
    return 0;
}
