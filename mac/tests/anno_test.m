/* anno_test.m: the annotation renderer, on a synthetic screenshot.
 *
 * No screen recording and no windows: the shot is a one-tile buffer with a black square at
 * its top-left and a green one at its bottom-right, so a flipped row order cannot hide.
 * The test adds a red rectangle, a numbered badge and a text, renders them into the same
 * path the copy uses (out_crop_annotated), and checks the pixels:
 *
 *   ./mac/build.sh annotest
 *
 * What it catches: annotations drawn at the wrong y (the base image is y-down, the bitmap
 * context is not), annotations missing from the copied PNG, and the copy path forgetting
 * the list. */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>

#include <stdio.h>
#include <string.h>

#include "annotate.h"
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

static bool near(uint32_t p, uint32_t want, int tol)
{
    int dr = (int)((p >> 16) & 0xFF) - (int)((want >> 16) & 0xFF);
    int dg = (int)((p >> 8) & 0xFF) - (int)((want >> 8) & 0xFF);
    int db = (int)(p & 0xFF) - (int)(want & 0xFF);
    return abs(dr) <= tol && abs(dg) <= tol && abs(db) <= tol;
}

static uint32_t *pixels_of(CGImageRef img, int *w, int *h)
{
    *w = (int)CGImageGetWidth(img);
    *h = (int)CGImageGetHeight(img);
    uint32_t *buf = calloc((size_t)*w * (size_t)*h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(buf, (size_t)*w, (size_t)*h, 8, (size_t)*w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(cg, CGRectMake(0, 0, *w, *h), img);
    CGContextRelease(cg);
    return buf;
}

static uint32_t at(const uint32_t *px, int w, int x, int y) { return px[(size_t)y * (size_t)w + (size_t)x] & 0xFFFFFF; }

static bool any_near(const uint32_t *px, int w, int x0, int y0, int r, uint32_t want, int tol)
{
    for (int y = y0 - r; y <= y0 + r; y++)
        for (int x = x0 - r; x <= x0 + r; x++)
            if (near(at(px, w, x, y), want, tol))
                return true;
    return false;
}

static SnipShot *make_shot(void)
{
    SnipShot *s = calloc(1, sizeof *s);
    s->ntile = 1;
    s->tile = calloc(1, sizeof(SnipTile));
    s->vs = (RECT){0, 0, 200, 150};
    s->tile[0].rc = s->vs;
    s->tile[0].scale = 1;
    s->tile[0].w = 200;
    s->tile[0].h = 150;
    s->tile[0].px = calloc(200 * 150, 4);
    for (int i = 0; i < 200 * 150; i++)
        s->tile[0].px[i] = 0xFFFFFFFFu; /* white */
    for (int y = 0; y < 10; y++)
        for (int x = 0; x < 10; x++)
            s->tile[0].px[y * 200 + x] = 0xFF000000u; /* black, top-left */
    for (int y = 140; y < 150; y++)
        for (int x = 190; x < 200; x++)
            s->tile[0].px[y * 200 + x] = 0xFF00FF00u; /* green, bottom-right */
    return s;
}

int main(void)
{
    @autoreleasepool {
        SnipShot *shot = make_shot();
        RECT sel = {0, 0, 200, 150};

        /* the base image alone: is the crop oriented like the source? */
        CGImageRef base = out_crop(shot, sel);
        CHECK(base != NULL, "crop failed");
        if (base) {
            int w = 0, h = 0;
            uint32_t *px = pixels_of(base, &w, &h);
            CHECK(w == 200 && h == 150, "crop is %dx%d", w, h);
            CHECK(near(at(px, w, 4, 4), 0x000000, 20), "top-left should be the black square, got #%06X",
                  at(px, w, 4, 4));
            CHECK(near(at(px, w, 195, 145), 0x00FF00, 20), "bottom-right should be green, got #%06X",
                  at(px, w, 195, 145));
            free(px);
            CGImageRelease(base);
        }

        AnnoList *l = anno_list_new();
        int r = anno_begin(l, T_RECT, 0xE53935, 2, CGPointMake(20, 20));
        anno_drag(l, r, CGPointMake(180, 120));
        anno_add_number(l, 0x1E88E5, 1, CGPointMake(100, 60), 1);
        anno_add_text(l, 0x43A047, 2, CGPointMake(30, 100), "snip");
        CHECK(anno_count(l) == 3, "expected 3 annotations, got %d", anno_count(l));

        CGImageRef img = out_crop_annotated(shot, sel, l);
        CHECK(img != NULL, "annotated crop failed");
        if (img) {
            int w = 0, h = 0;
            uint32_t *px = pixels_of(img, &w, &h);
            CHECK(w == 200 && h == 150, "annotated crop is %dx%d", w, h);
            /* the rectangle's stroke: red near its top-left corner, and nothing red near
             * the mirrored position at the bottom-left */
            CHECK(any_near(px, w, 20, 20, 8, 0xE53935, 40), "the rectangle is not at its top-left corner");
            CHECK(!any_near(px, w, 20, 130, 8, 0xE53935, 40), "the rectangle is mirrored vertically");
            /* the numbered badge: blue disc at its point */
            CHECK(any_near(px, w, 100, 60, 14, 0x1E88E5, 40), "the numbered badge is missing at 100,60");
            /* the text: some green ink around its point */
            CHECK(any_near(px, w, 40, 108, 14, 0x43A047, 60), "the text is missing");
            free(px);
            CGImageRelease(img);
        }

        /* saving goes through the same renderer */
        {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"sniplite-anno-test.png"];
            CGImageRef save = out_crop_annotated(shot, sel, l);
            CHECK(save && out_write_image(save, path), "save failed");
            if (save) {
                NSData *d = [NSData dataWithContentsOfFile:path];
                CHECK(d.length > 0, "the saved file is empty");
                CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
                CGImageRef back = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
                CHECK(back && CGImageGetWidth(back) == 200 && CGImageGetHeight(back) == 150,
                      "the saved PNG is not the selection's size");
                if (back)
                    CGImageRelease(back);
                if (src)
                    CFRelease(src);
                [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
                CGImageRelease(save);
            }
        }

        /* a Retina (2x) tile: the crop must come out at 2x, in the right place */
        SnipShot *r2 = calloc(1, sizeof *r2);
        r2->ntile = 1;
        r2->tile = calloc(1, sizeof(SnipTile));
        r2->vs = (RECT){0, 0, 100, 80};
        r2->tile[0].rc = r2->vs;
        r2->tile[0].scale = 2;
        r2->tile[0].w = 200;
        r2->tile[0].h = 160;
        r2->tile[0].px = calloc(200 * 160, 4);
        for (int i = 0; i < 200 * 160; i++)
            r2->tile[0].px[i] = 0xFFFFFFFFu;
        r2->tile[0].px[0] = 0xFFFF0000u;             /* global 0,0: red */
        r2->tile[0].px[80 * 200 + 100] = 0xFF00FF00u; /* pixel 100,80 = global 50,40: green */
        r2->tile[0].px[42 * 200 + 22] = 0xFF0000FFu;  /* pixel 22,42 = global 11,21: blue */
        CGImageRef rim = out_crop(r2, (RECT){10, 20, 60, 60});
        CHECK(rim != NULL, "the 2x crop failed");
        if (rim) {
            int w = 0, h = 0;
            uint32_t *px = pixels_of(rim, &w, &h);
            printf("retina crop %dx%d\n", w, h);
            CHECK(w == 100 && h == 80, "a 2x crop of 50x40 points is %dx%d pixels, expected 100x80", w, h);
            CHECK(near(at(px, w, 2, 2), 0x0000FF, 20), "the 2x crop is not at the right place: #%06X", at(px, w, 2, 2));
            free(px);
            CGImageRelease(rim);
        }
        free(r2->tile[0].px);
        free(r2->tile);
        free(r2);

        /* two displays with different scales: a selection that crosses them is sampled
         * through each tile (the output is at the scale of the top-left corner's tile) */
        SnipShot *mix = calloc(1, sizeof *mix);
        mix->ntile = 2;
        mix->tile = calloc(2, sizeof(SnipTile));
        mix->vs = (RECT){0, 0, 200, 80};
        for (int i = 0; i < 2; i++) {
            mix->tile[i].rc = (RECT){i * 100, 0, 100 + i * 100, 80};
            mix->tile[i].scale = i == 0 ? 1 : 2;
            mix->tile[i].w = (i == 0 ? 100 : 200);
            mix->tile[i].h = (i == 0 ? 80 : 160);
            mix->tile[i].px = calloc((size_t)mix->tile[i].w * (size_t)mix->tile[i].h, 4);
            for (int k = 0; k < mix->tile[i].w * mix->tile[i].h; k++)
                mix->tile[i].px[k] = i == 0 ? 0xFF0000FFu : 0xFFFF0000u; /* A blue, B red */
        }
        CGImageRef mim = out_crop(mix, (RECT){90, 0, 110, 40});
        CHECK(mim != NULL, "the mixed-scale crop failed");
        if (mim) {
            int w = 0, h = 0;
            uint32_t *px = pixels_of(mim, &w, &h);
            printf("mixed crop %dx%d\n", w, h);
            CHECK(w == 20 && h == 40, "the mixed crop is %dx%d, expected 20x40 (1x corner)", w, h);
            CHECK(near(at(px, w, 2, 20), 0x0000FF, 20), "the left of the mixed crop is not tile A");
            CHECK(near(at(px, w, 15, 20), 0xFF0000, 20), "the right of the mixed crop is not tile B");
            free(px);
            CGImageRelease(mim);
        }
        for (int i = 0; i < 2; i++)
            free(mix->tile[i].px);
        free(mix->tile);
        free(mix);

        /* saving to a file: PNG and JPEG decode back to the same size */
        NSString *pngPath = @"/tmp/sniplite-anno-test.png";
        NSString *jpgPath = @"/tmp/sniplite-anno-test.jpg";
        CHECK(out_save_annotated(shot, sel, l, pngPath), "saving the PNG failed");
        CHECK(out_save_annotated(shot, sel, l, jpgPath), "saving the JPEG failed");
        for (NSString *path in @[ pngPath, jpgPath ]) {
            NSData *d = [NSData dataWithContentsOfFile:path];
            CGImageSourceRef src = d.length ? CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL) : NULL;
            CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
            CHECK(img != NULL, "%s did not decode", path.UTF8String);
            if (img) {
                CHECK(CGImageGetWidth(img) == 200 && CGImageGetHeight(img) == 150, "%s is %zux%zu",
                      path.UTF8String, CGImageGetWidth(img), CGImageGetHeight(img));
                CGImageRelease(img);
            }
            if (src)
                CFRelease(src);
        }
        [[NSFileManager defaultManager] removeItemAtPath:pngPath error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:jpgPath error:NULL];

        /* the copy path: the same pixels must reach the pasteboard */
        CHECK(out_copy_annotated(shot, sel, l), "copy with annotations failed");
        NSData *png = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypePNG];
        CHECK(png.length > 0, "no PNG on the pasteboard");
        if (png.length) {
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
            CGImageRef back = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
            CHECK(back != NULL, "the pasted PNG does not decode");
            if (back) {
                int w = 0, h = 0;
                uint32_t *px = pixels_of(back, &w, &h);
                CHECK(near(at(px, w, 4, 4), 0x000000, 20), "the pasted image lost the top-left corner");
                CHECK(any_near(px, w, 20, 20, 8, 0xE53935, 40), "the pasted image has no annotation");
                free(px);
                CGImageRelease(back);
            }
            if (src)
                CFRelease(src);
        }

        /* the plan's budget: 100 annotations, one redraw, under 50 ms */
        {
            SnipShot *big = calloc(1, sizeof *big);
            big->ntile = 1;
            big->tile = calloc(1, sizeof(SnipTile));
            big->vs = (RECT){0, 0, 1600, 1000};
            big->tile[0].rc = big->vs;
            big->tile[0].scale = 1;
            big->tile[0].w = 1600;
            big->tile[0].h = 1000;
            big->tile[0].px = calloc(1600 * 1000, 4);
            for (int i = 0; i < 1600 * 1000; i++)
                big->tile[0].px[i] = 0xFF303030u;
            AnnoList *many = anno_list_new();
            for (int i = 0; i < 100; i++) {
                int tool = T_RECT + (i % 9);
                CGPoint a = CGPointMake((CGFloat)(i * 15 % 1500), (CGFloat)(i * 9 % 900));
                if (tool == T_TEXT) {
                    anno_add_text(many, 0xE53935, i % 3, a, "label");
                } else if (tool == T_NUMBER) {
                    anno_add_number(many, 0x1E88E5, i % 3, a, i + 1);
                } else {
                    int k = anno_begin(many, tool, 0x43A047, i % 3, a);
                    for (int step = 1; step <= 6; step++)
                        anno_drag(many, k, CGPointMake(a.x + step * 12, a.y + step * 7));
                }
            }
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            CGImageRef redraw = out_crop_annotated(big, big->vs, many);
            double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
            printf("100 annotations redraw: %.1f ms\n", ms);
            CHECK(redraw != NULL, "the 100-annotation redraw failed");
            CHECK(ms < 50.0, "the 100-annotation redraw took %.1f ms (budget 50 ms)", ms);
            if (redraw)
                CGImageRelease(redraw);
            anno_list_free(many);
            free(big->tile[0].px);
            free(big->tile);
            free(big);
        }

        /* undo history: the snapshots are independent of the live list */
        AnnoHist h;
        AnnoList *live = anno_list_new();
        anno_hist_init(&h, live);
        CHECK(!anno_hist_can_undo(&h), "a fresh history can undo");
        anno_begin(live, T_RECT, 0xE53935, 1, CGPointMake(5, 5));
        anno_hist_push(&h, live);
        CHECK(anno_hist_can_undo(&h), "an edit cannot be undone");
        const AnnoList *u = anno_hist_undo(&h);
        CHECK(u && anno_count(u) == 0, "undo did not go back to the empty list");
        u = anno_hist_redo(&h);
        CHECK(u && anno_count(u) == 1, "redo did not restore the annotation");
        AnnoList *c = anno_list_clone(l);
        CHECK(anno_count(c) == anno_count(l), "clone lost annotations");
        anno_begin(c, T_RECT, 0x000000, 1, CGPointMake(1, 1));
        CHECK(anno_count(c) == anno_count(l) + 1 && anno_count(l) == 3, "clone shares its storage with the source");
        anno_list_free(c);
        anno_hist_free(&h);
        anno_list_free(live);

        anno_list_free(l);
        free(shot->tile[0].px);
        free(shot->tile);
        free(shot);
        printf("%d passed, %d failed\n", g_pass, g_fail);
    }
    return g_fail ? 1 : 0;
}
