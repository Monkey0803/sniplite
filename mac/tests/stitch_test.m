/* stitch_test.m: the long screenshot's stitching, on synthetic pages.
 *
 * No screen: a tall "page" of deterministic pixels is cut into frames at known scroll
 * offsets, and the canvas the stitcher builds must be that page, row for row:
 *
 *   ./mac/build.sh stitchtest
 */
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "stitch.h"

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

static uint32_t rnd(uint32_t *st)
{
    *st ^= *st << 13;
    *st ^= *st >> 17;
    *st ^= *st << 5;
    return *st;
}

static const int W = 240, H = 2400, FH = 600;

static uint32_t *make_page(void)
{
    uint32_t *p = malloc((size_t)W * H * 4);
    uint32_t seed = 0x12345678;
    for (int i = 0; i < W * H; i++)
        p[i] = 0xFF000000u | (rnd(&seed) & 0xFFFFFF);
    return p;
}

static const uint32_t *frame_at(const uint32_t *page, int y)
{
    return page + (size_t)y * W;
}

int main(void)
{
    @autoreleasepool {
        uint32_t *page = make_page();
        Stitch s;
        CHECK(stitch_init(&s, W, FH), "stitch_init failed");

        int offs[] = {0, 250, 500, 750};
        int rows = 0;
        for (int i = 0; i < 4; i++) {
            int added = stitch_feed(&s, frame_at(page, offs[i]));
            int expect = offs[i] + FH;
            rows = stitch_rows(&s);
            printf("frame at %4d: +%d rows, canvas %d (expect %d)\n", offs[i], added, rows, expect);
            CHECK(rows == expect, "frame at %d: canvas %d, expected %d", offs[i], rows, expect);
        }

        /* every row of the canvas must be the page's row */
        int bad = 0;
        for (int r = 0; r < rows && !bad; r++)
            if (memcmp(stitch_canvas(&s) + (size_t)r * W, frame_at(page, 0) + (size_t)r * W, (size_t)W * 4) != 0)
                bad = r + 1;
        CHECK(!bad, "canvas row %d differs from the page", bad - 1);

        /* the same frame twice: the page did not move, nothing is added */
        int before = stitch_rows(&s);
        int added = stitch_feed(&s, frame_at(page, 750));
        CHECK(added == 0 && stitch_rows(&s) == before, "an unchanged frame grew the canvas");

        /* an unrelated frame is refused instead of corrupting the canvas */
        uint32_t *noise = malloc((size_t)W * FH * 4);
        uint32_t seed = 0xDEADBEEF;
        for (int i = 0; i < W * FH; i++)
            noise[i] = rnd(&seed) | 0xFF000000u;
        added = stitch_feed(&s, noise);
        CHECK(added <= 0 && stitch_rows(&s) == before, "an unrelated frame grew the canvas");
        free(noise);

        stitch_finish(&s);
        CHECK(stitch_rows(&s) >= before, "finish lost rows");

        stitch_free(&s);
        free(page);

        printf("%d passed, %d failed\n", g_pass, g_fail);
    }
    return g_fail ? 1 : 0;
}
