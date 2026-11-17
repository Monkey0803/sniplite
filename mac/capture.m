/* capture.m: one frozen frame of every display through ScreenCaptureKit, and the
 * windows on top of a point.
 *
 * What the port does not keep from src/shot.S: DXGI desktop duplication, D3D11 textures
 * and GDI fallbacks. ScreenCaptureKit hands back a CGImage per display, which is turned
 * into the same top-down BGRX buffer the shared drawing code (draw.h) works on, so the
 * annotation core stays the one written for Windows.
 *
 * Coordinates: every rect here is global top-left points (the space event locations are
 * converted to), and each tile remembers the scale that turns its points into pixels.
 * The overlay is one window over the union of the displays, so a selection may cross
 * displays; the output is sampled through the tiles. */
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <math.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"
#include "common.h"   /* rect_union and the rest of the shared helpers */

static char g_error[256];
static SCShareableContent *g_content; /* cached: displays change rarely */
static double g_content_at;

static void set_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_error, sizeof g_error, fmt, ap);
    va_end(ap);
    snip_log("capture: %s", g_error);
}

const char *cap_last_error(void) { return g_error; }

/* ---- permission ------------------------------------------------------------------ */

bool cap_permission(void) { return CGPreflightScreenCaptureAccess() != 0; }

void cap_request_permission(void)
{
    snip_log("asking for the screen recording permission");
    CGRequestScreenCaptureAccess();
}

/* ---- displays -------------------------------------------------------------------- */

typedef struct {
    CGDirectDisplayID id;
    RECT rc; /* global top-left points */
    float scale;
} DisplayDesc;

static CGFloat g_top; /* the largest NSMaxY of all screens: turns bottom-left into top-left */

static DisplayDesc *display_descs(int *count)
{
    NSArray<NSScreen *> *screens = [NSScreen screens];
    g_top = 0;
    for (NSScreen *s in screens)
        g_top = MAX(g_top, NSMaxY(s.frame));
    DisplayDesc *d = calloc(screens.count ? screens.count : 1, sizeof *d);
    int n = 0;
    for (NSScreen *s in screens) {
        CGDirectDisplayID did = (CGDirectDisplayID)[s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        NSRect f = s.frame;
        RECT rc = {(LONG)lround(f.origin.x), (LONG)lround(g_top - NSMaxY(f)), (LONG)lround(f.origin.x + f.size.width),
                   (LONG)lround(g_top - f.origin.y)};
        d[n].id = did;
        d[n].rc = rc;
        d[n].scale = (float)s.backingScaleFactor;
        n++;
    }
    *count = n;
    return d;
}

static SCDisplay *find_display(SCShareableContent *content, CGDirectDisplayID id)
{
    for (SCDisplay *d in content.displays)
        if (d.displayID == id)
            return d;
    return nil;
}

/* ---- content cache ---------------------------------------------------------------- */

static void fetch_content(void (^done)(SCShareableContent *))
{
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                               onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *c, NSError *e) {
                                                   dispatch_async(dispatch_get_main_queue(), ^{
                                                     if (c) {
                                                         g_content = c;
                                                         g_content_at = CFAbsoluteTimeGetCurrent();
                                                     } else {
                                                         set_error("shareable content: %s",
                                                                   e.localizedDescription.UTF8String ?: "unknown error");
                                                     }
                                                     done(c);
                                                   });
                                                 }];
}

static void with_content(void (^done)(SCShareableContent *))
{
    if (g_content && CFAbsoluteTimeGetCurrent() - g_content_at < 2.0) {
        done(g_content);
        return;
    }
    fetch_content(done);
}

void cap_invalidate(void)
{
    g_content = nil;
    g_content_at = 0;
}

void cap_prewarm(void)
{
    if (!cap_permission()) {
        snip_log("no screen recording permission yet: the first capture will ask");
        return;
    }
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    fetch_content(^(SCShareableContent *c) {
      if (!c || !c.displays.count) {
          snip_log("prewarm: no displays");
          return;
      }
      /* One tiny capture warms the ScreenCaptureKit pipeline; without it the first real
       * capture pays several hundred milliseconds (measured in Phase 0). */
      SCDisplay *d = c.displays.firstObject;
      SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
      SCStreamConfiguration *cfg = [SCStreamConfiguration new];
      cfg.width = 32;
      cfg.height = 32;
      cfg.showsCursor = NO;
      double t1 = CFAbsoluteTimeGetCurrent();
      [SCScreenshotManager captureImageWithFilter:filter
                                     configuration:cfg
                                completionHandler:^(CGImageRef img, NSError *e) {
                                  (void)img;
                                  snip_log("prewarm: %d displays in %.1f ms, warm capture %.1f ms%s", (int)c.displays.count,
                                           (t1 - t0) * 1000.0, (CFAbsoluteTimeGetCurrent() - t1) * 1000.0,
                                           e ? " (failed)" : "");
                                }];
    });
}

/* ---- frames ---------------------------------------------------------------------- */

/* Draw a CGImage into a BGRX buffer (top-down, stride == w). */
static uint32_t *image_to_bgrx(CGImageRef img, int *out_w, int *out_h)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (!w || !h || w * h > (size_t)1 << 28)
        return NULL;
    uint32_t *px = calloc(w * h, 4);
    if (!px)
        return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        free(px);
        return NULL;
    }
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGContextRelease(ctx);
    *out_w = (int)w;
    *out_h = (int)h;
    return px;
}

static void cap_one(SCDisplay *d, RECT rc, float scale, void (^done)(uint32_t *px, int w, int h))
{
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
    SCStreamConfiguration *cfg = [SCStreamConfiguration new];
    cfg.width = (size_t)MAX(1, lround((rc.right - rc.left) * scale));
    cfg.height = (size_t)MAX(1, lround((rc.bottom - rc.top) * scale));
    cfg.showsCursor = NO;
    cfg.captureResolution = SCCaptureResolutionBest;
    if (@available(macOS 14.2, *))
        filter.includeMenuBar = YES;

    double t0 = CFAbsoluteTimeGetCurrent();
    [SCScreenshotManager captureImageWithFilter:filter
                                   configuration:cfg
                              completionHandler:^(CGImageRef img, NSError *e) {
                                double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
                                uint32_t *px = NULL;
                                int w = 0, h = 0;
                                if (img)
                                    px = image_to_bgrx(img, &w, &h);
                                else
                                    set_error("display %u: %s", (unsigned)d.displayID,
                                              e.localizedDescription.UTF8String ?: "no image");
                                snip_log("display %u capture %.1f ms", (unsigned)d.displayID, ms);
                                dispatch_async(dispatch_get_main_queue(), ^{
                                  done(px, w, h);
                                });
                              }];
}

void cap_take(void (^done)(SnipShot *shot))
{
    if (!cap_permission()) {
        set_error("screen recording permission not granted");
        done(NULL);
        return;
    }
    int nd = 0;
    DisplayDesc *desc = display_descs(&nd);
    if (!nd) {
        free(desc);
        set_error("no displays");
        done(NULL);
        return;
    }

    RECT vs = desc[0].rc;
    for (int i = 1; i < nd; i++)
        vs = rect_union(vs, desc[i].rc);

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __block BOOL finished = NO;
    __block BOOL aborted = NO;
    /* hoisted so the timeout can drop the tiles: ScreenCaptureKit can hang forever when
     * the permission dialog is up, and the frames that did arrive must not leak */
    __block SnipShot shot = {0};
    __block int left = nd;
    void (^finish)(SnipShot *) = ^(SnipShot *s) {
      if (finished)
          return;
      finished = YES;
      if (s)
          s->ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
      done(s);
    };
    /* a stuck capture (permission dialog) must not leave the overlay waiting forever */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (!finished) {
          aborted = YES;
          if (shot.tile) {
              for (int k = 0; k < nd; k++)
                  free(shot.tile[k].px);
              free(shot.tile);
              shot.tile = NULL;
          }
          set_error("capture timed out");
          finish(NULL);
      }
    });

    with_content(^(SCShareableContent *content) {
      if (!content) {
          free(desc);
          finish(NULL);
          return;
      }
      shot.tile = calloc((size_t)nd, sizeof(SnipTile));
      for (int i = 0; i < nd; i++) {
          SCDisplay *d = find_display(content, desc[i].id);
          if (!d) {
              set_error("display %u missing from ScreenCaptureKit", (unsigned)desc[i].id);
              left--;
              continue;
          }
          shot.tile[i].rc = desc[i].rc;
          shot.tile[i].scale = desc[i].scale;
          __block int idx = i;
          cap_one(d, desc[i].rc, desc[i].scale, ^(uint32_t *px, int w, int h) {
            if (aborted) { /* the timeout already reported and freed the tiles */
                free(px);
                return;
            }
            if (!px) {
                set_error("display %u: no pixels", (unsigned)desc[idx].id);
            } else {
                shot.tile[idx].px = px;
                shot.tile[idx].w = w;
                shot.tile[idx].h = h;
            }
            if (--left == 0) {
                /* keep only the tiles that arrived, and report the union of those */
                int n = 0;
                for (int k = 0; k < nd; k++)
                    if (shot.tile[k].px)
                        shot.tile[n++] = shot.tile[k];
                shot.ntile = n;
                shot.vs = vs;
                if (!n) {
                    set_error("no display could be captured");
                    free(shot.tile);
                    shot.tile = NULL;
                    finish(NULL);
                } else {
                    finish(&shot);
                }
            }
          });
      }
      free(desc);
      if (left == 0) { /* every display was missing: nothing will call back */
          set_error("no capturable display");
          free(shot.tile);
          shot.tile = NULL;
          finish(NULL);
      }
    });
}

void cap_free(SnipShot *shot)
{
    if (!shot)
        return;
    for (int i = 0; i < shot->ntile; i++)
        free(shot->tile[i].px);
    free(shot->tile);
    memset(shot, 0, sizeof *shot);
}

/* ---- one region --------------------------------------------------------------------- */

static void sample_from_image(CGImageRef img, void (^done)(uint32_t *, int, int))
{
    uint32_t *px = NULL;
    int w = 0, h = 0;
    if (img)
        px = image_to_bgrx(img, &w, &h);
    else
        set_error("sample: no image");
    dispatch_async(dispatch_get_main_queue(), ^{
      done(px, w, h);
    });
}

void cap_sample_rect(RECT r, void (^done)(uint32_t *px, int w, int h))
{
    int wpt = (int)(r.right - r.left), hpt = (int)(r.bottom - r.top);
    if (wpt < 1 || hpt < 1 || !cap_permission()) {
        if (!cap_permission())
            set_error("screen recording permission not granted");
        done(NULL, 0, 0);
        return;
    }
    if (@available(macOS 15.2, *)) {
        if ([SCScreenshotManager respondsToSelector:@selector(captureImageInRect:completionHandler:)]) {
            [SCScreenshotManager captureImageInRect:CGRectMake(r.left, r.top, wpt, hpt)
                                  completionHandler:^(CGImageRef img, NSError *e) {
                                    if (e)
                                        set_error("sample: %s", e.localizedDescription.UTF8String ?: "?");
                                    sample_from_image(img, done);
                                  }];
            return;
        }
    }
    /* older systems: the display's own filter, limited to the region with sourceRect */
    int nd = 0;
    DisplayDesc *d = display_descs(&nd);
    DisplayDesc *dd = NULL;
    for (int i = 0; i < nd && !dd; i++)
        if (rect_has(&d[i].rc, (r.left + r.right) / 2, (r.top + r.bottom) / 2))
            dd = &d[i];
    if (!dd) {
        free(d);
        set_error("sample: region on no display");
        done(NULL, 0, 0);
        return;
    }
    DisplayDesc desc = *dd;
    free(d);
    with_content(^(SCShareableContent *content) {
      SCDisplay *sd = content ? find_display(content, desc.id) : nil;
      if (!sd) {
          set_error("sample: display gone");
          done(NULL, 0, 0);
          return;
      }
      SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:sd excludingWindows:@[]];
      SCStreamConfiguration *cfg = [SCStreamConfiguration new];
      cfg.width = (size_t)lround(wpt * desc.scale);
      cfg.height = (size_t)lround(hpt * desc.scale);
      cfg.sourceRect = CGRectMake(r.left - desc.rc.left, r.top - desc.rc.top, wpt, hpt);
      cfg.showsCursor = NO;
      cfg.captureResolution = SCCaptureResolutionBest;
      [SCScreenshotManager captureImageWithFilter:filter
                                     configuration:cfg
                                completionHandler:^(CGImageRef img, NSError *e) {
                                  if (e)
                                      set_error("sample: %s", e.localizedDescription.UTF8String ?: "?");
                                  sample_from_image(img, done);
                                }];
    });
}

/* ---- windows ---------------------------------------------------------------------- */

int cap_windows_at(int x, int y, RECT *out, int max)
{
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                                    kCGWindowListExcludeDesktopElements,
                                                                kCGNullWindowID));
    pid_t self = getpid();
    int n = 0;
    for (NSDictionary *w in list) {
        if ([w[(id)kCGWindowLayer] intValue] != 0)
            continue; /* menus, dock, status items: not a window the user means */
        if ([w[(id)kCGWindowOwnerPID] intValue] == self)
            continue;
        if ([w[(id)kCGWindowAlpha] doubleValue] < 0.01)
            continue;
        CGRect b = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &b))
            continue;
        if (b.size.width < 8 || b.size.height < 8)
            continue;
        RECT rc = {(LONG)lround(b.origin.x), (LONG)lround(b.origin.y), (LONG)lround(b.origin.x + b.size.width),
                   (LONG)lround(b.origin.y + b.size.height)};
        if (x < rc.left || x >= rc.right || y < rc.top || y >= rc.bottom)
            continue;
        if (out && n < max)
            out[n] = rc;
        n++;
        if (n >= max)
            break;
    }
    return n;
}
