/* longscreen.m: the long screenshot's windows and sampling loop.
 *
 * After a selection is made with the long screenshot tool the capture overlay goes away
 * and this takes over: a thin frame around the region, a bar under it with copy/save/pin/
 * close, and a strip beside it with the picture built so far. The user scrolls the page
 * themselves, in whatever application it is; nothing is sent to it. Every ~100 ms the
 * region is read again (ScreenCaptureKit) and handed to the stitcher (stitch.c), which
 * decides where the new frame belongs and appends the rows below.
 *
 * Esc and Return are registered as global hotkeys while this runs, because the keyboard
 * belongs to the page being scrolled, exactly like the Windows version does. */
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"
#include "common.h"
#include "draw_cg.h"
#include "icons.h"
#include "lang.h"
#include "longscreen.h"
#include "output.h"
#include "ov_layout.inc" /* ACCENT */
#include "pin.h"
#include "plat.h"
#include "stitch.h"

#define BAR_W 430.0
#define BAR_H 38.0
#define PREVIEW_W 150.0
#define GAP 8.0
#define FRAME_T 2.0
#define THUMB_W 150
#define TICK_S 0.1

static Stitch g_st;
static RECT g_rc;
static bool g_on;
static int g_w, g_h;     /* the frame's pixel size */
static int g_wpt, g_hpt; /* the region in points */
static CGFloat g_top;    /* NSMaxY of the topmost screen */

static NSWindow *g_bar, *g_preview, *g_frame[4];
static NSView *g_barView, *g_previewView;
static NSTimer *g_timer;
static bool g_pending;
static int g_hover = -1, g_down = -1;
static NSString *g_status;

static uint32_t *g_thumb;
static int g_thumbCap, g_thumbRows, g_thumbW;

static EventHotKeyRef g_hkEsc, g_hkRet;
static EventHandlerRef g_hkHandler;
static bool g_hkOK;

enum { LB_OK, LB_SAVE, LB_PIN, LB_CLOSE, LB_COUNT };
static const int kBarIcon[LB_COUNT] = {IC_OK, IC_SAVE, IC_PIN, IC_CLOSE};

void long_finish(bool copy, bool save, bool pin);
static void tick(void);
static void update_ui(void);

/* ---- text ------------------------------------------------------------------------------ */

static NSString *wstr(const WCHAR *s)
{
    char *u = snip_wstr_to_utf8(s);
    NSString *r = u ? [NSString stringWithUTF8String:u] : @"";
    free(u);
    return r;
}

/* ---- images ---------------------------------------------------------------------------- */

static int w_img_w(CGImageRef img) { return img ? (int)CGImageGetWidth(img) : 0; }

static void free_data(void *info, const void *data, size_t size)
{
    (void)info;
    (void)size;
    free((void *)data);
}

static CGImageRef image_from_bgrx(const uint32_t *px, int w, int h, bool copy)
{
    if (!px || w < 1 || h < 1)
        return NULL;
    void *data = (void *)px;
    if (copy) {
        data = malloc((size_t)w * (size_t)h * 4);
        if (!data)
            return NULL;
        memcpy(data, px, (size_t)w * (size_t)h * 4);
    }
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, data, (size_t)w * (size_t)h * 4, copy ? free_data : NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs,
                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, prov, NULL, false,
                                   kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(prov);
    return img;
}

/* ---- the preview ----------------------------------------------------------------------- */

static void thumb_update(void)
{
    if (!g_thumb || g_thumbW < 1 || g_w < 1)
        return;
    int w = g_w, rows = stitch_rows(&g_st);
    for (; g_thumbRows < g_thumbCap && (int64_t)(g_thumbRows + 1) * w / g_thumbW <= rows; g_thumbRows++) {
        int y0 = g_thumbRows * w / g_thumbW, y1 = (g_thumbRows + 1) * w / g_thumbW;
        if (y0 >= y1 || y1 > rows)
            break;
        uint32_t *d = g_thumb + (size_t)g_thumbRows * g_thumbW;
        const uint32_t *canvas = stitch_canvas(&g_st);
        for (int x = 0; x < g_thumbW; x++) {
            int xa = x * w / g_thumbW, xb = (x + 1) * w / g_thumbW;
            unsigned b = 0, gg = 0, r = 0, n = 0;
            for (int y = y0; y < y1; y++) {
                const uint32_t *p = canvas + (size_t)y * (size_t)w;
                for (int i = xa; i < xb; i++) {
                    uint32_t v = p[i];
                    b += v & 255;
                    gg += (v >> 8) & 255;
                    r += (v >> 16) & 255;
                    n++;
                }
            }
            if (!n)
                n = 1;
            d[x] = ((r / n) << 16) | ((gg / n) << 8) | (b / n);
        }
    }
}

@interface LongPreviewView : NSView
@end

@implementation LongPreviewView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r
{
    (void)r;
    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
    CGRect b = self.bounds;
    CGContextSetFillColorWithColor(cg, [NSColor colorWithCalibratedWhite:0.10 alpha:1].CGColor);
    CGContextFillRect(cg, b);
    if (!g_thumb || g_thumbRows < 1)
        return;
    int shown = MIN(g_thumbRows, (int)floor(b.size.height));
    int from = g_thumbRows - shown;
    CGImageRef img = image_from_bgrx(g_thumb + (size_t)from * g_thumbW, g_thumbW, shown, false);
    if (img) {
        CGContextSaveGState(cg);
        CGContextTranslateCTM(cg, 0, CGRectGetMaxY(b));
        CGContextScaleCTM(cg, 1, -1);
        CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
        CGContextDrawImage(cg, CGRectMake(0, 0, b.size.width, shown), img);
        CGContextRestoreGState(cg);
        CGImageRelease(img);
    }
    CGContextSetFillColorWithColor(cg, [NSColor colorWithCalibratedWhite:0.16 alpha:1].CGColor);
    CGContextFillRect(cg, CGRectMake(0, shown, b.size.width, b.size.height - shown));
    if (!g_st.lost && g_w > 0) {
        CGRect now = CGRectMake(0, (CGFloat)g_st.pos * g_thumbW / g_w - from, b.size.width,
                                (CGFloat)g_st.h * g_thumbW / g_w);
        if (now.origin.y < 0)
            now.origin.y = 0;
        if (now.size.height > shown)
            now.size.height = shown;
        if (now.size.height > 0) {
            CGContextSetStrokeColorWithColor(cg, [NSColor colorWithSRGBRed:(CGFloat)(ACCENT >> 16) / 255.0
                                                                   green:(CGFloat)((ACCENT >> 8) & 0xFF) / 255.0
                                                                    blue:(CGFloat)(ACCENT & 0xFF) / 255.0
                                                                   alpha:1]
                                              .CGColor);
            CGContextSetLineWidth(cg, 1);
            CGContextStrokeRect(cg, CGRectInset(now, 1, 1));
        }
    }
}
@end

/* ---- the bar --------------------------------------------------------------------------- */

@interface LongBarView : NSView
@end

@implementation LongBarView
- (BOOL)isFlipped { return YES; }

- (CGRect)button:(int)i
{
    double b = 28, gap = 4, right = self.bounds.size.width - 8;
    return CGRectMake(right - (LB_COUNT - i) * (b + gap) + gap, (self.bounds.size.height - b) / 2, b, b);
}

- (int)button_at:(CGPoint)p
{
    for (int i = 0; i < LB_COUNT; i++)
        if (CGRectContainsPoint(CGRectInset([self button:i], -3, -3), p))
            return i;
    return -1;
}

- (void)drawRect:(NSRect)r
{
    (void)r;
    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
    CGRect b = self.bounds;
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectInset(b, 0.5, 0.5), 8, 8, NULL);
    CGContextSetFillColorWithColor(cg, [NSColor colorWithCalibratedWhite:0.11 alpha:0.97].CGColor);
    CGContextAddPath(cg, path);
    CGContextFillPath(cg);
    CGPathRelease(path);
    CGContextSetStrokeColorWithColor(cg, [NSColor colorWithCalibratedWhite:1 alpha:0.14].CGColor);
    CGContextSetLineWidth(cg, 1);
    CGContextStrokeRect(cg, CGRectInset(b, 0.5, 0.5));

    for (int i = 0; i < LB_COUNT; i++) {
        CGRect rc = [self button:i];
        if (g_hover == i || g_down == i) {
            CGPathRef p = CGPathCreateWithRoundedRect(CGRectInset(rc, -2, -2), 6, 6, NULL);
            CGContextSetFillColorWithColor(cg,
                                           [NSColor colorWithCalibratedWhite:1 alpha:(g_down == i ? 0.22 : 0.14)].CGColor);
            CGContextAddPath(cg, p);
            CGContextFillPath(cg);
            CGPathRelease(p);
        }
        dc_icon(cg, kBarIcon[i], CGRectInset(rc, 5, 5), i == LB_OK ? ACCENT : 0xF0F0F0);
    }

    NSString *text = g_status ?: @"";
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:12],
                            NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:0.85 alpha:1]};
    [text drawAtPoint:NSMakePoint(12, (b.size.height - [text sizeWithAttributes:attrs].height) / 2)
       withAttributes:attrs];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas)
        [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseMoved | NSTrackingActiveAlways |
                                                               NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)e
{
    int h = [self button_at:[self convertPoint:e.locationInWindow fromView:nil]];
    if (h != g_hover) {
        g_hover = h;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)e
{
    g_down = [self button_at:[self convertPoint:e.locationInWindow fromView:nil]];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e
{
    int b = [self button_at:[self convertPoint:e.locationInWindow fromView:nil]];
    int had = g_down;
    g_down = -1;
    [self setNeedsDisplay:YES];
    if (b < 0 || b != had)
        return;
    if (b == LB_OK)
        long_finish(true, false, false);
    else if (b == LB_SAVE)
        long_finish(false, true, false);
    else if (b == LB_PIN)
        long_finish(false, false, true);
    else
        long_cancel();
}
@end

/* ---- timers and hotkeys ----------------------------------------------------------------- */

@interface LongPump : NSObject
@end

@implementation LongPump
- (void)fire:(NSTimer *)t
{
    (void)t;
    tick();
}
@end

static LongPump *g_pump;

static OSStatus on_hotkey(EventHandlerCallRef call, EventRef ev, void *ud)
{
    (void)call;
    (void)ud;
    EventHotKeyID id;
    if (GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id) != noErr ||
        id.signature != 'SNLG')
        return noErr;
    if (id.id == 1)
        long_cancel();
    else
        long_finish(true, false, false);
    return noErr;
}

static void update_ui(void)
{
    int rows = stitch_rows(&g_st);
    if (g_st.full)
        g_status = wstr(T(LONG_FULL));
    else if (g_st.lost)
        g_status = wstr(T(LONG_LOST));
    else if (rows <= g_h)
        g_status = wstr(T(LONG_HINT));
    else
        g_status = [NSString stringWithFormat:@"%d × %d", g_w, rows];
    thumb_update();
    [g_barView setNeedsDisplay:YES];
    [g_previewView setNeedsDisplay:YES];
}

static void tick(void)
{
    if (!g_on || g_pending)
        return;
    g_pending = true;
    cap_sample_rect(g_rc, ^(uint32_t *px, int w, int h) {
      g_pending = false;
      if (!g_on) {
          free(px);
          return;
      }
      if (!px) {
          g_status = wstr(T(LONG_LOST));
          [g_barView setNeedsDisplay:YES];
          return;
      }
      if (!g_w) {
          g_w = w;
          g_h = h;
          if (!stitch_init(&g_st, w, h)) {
              free(px);
              long_cancel();
              return;
          }
          g_thumbW = THUMB_W;
          g_thumbCap = (int)((int64_t)g_st.max_rows * g_thumbW / w) + 2;
          g_thumb = calloc((size_t)g_thumbCap * g_thumbW, 4);
      }
      if (w != g_w || h != g_h) {
          free(px);
          return;
      }
      stitch_feed(&g_st, px);
      free(px);
      update_ui();
    });
}

/* ---- showing and closing ---------------------------------------------------------------- */

static NSWindow *make_window(NSRect frame, NSView *view, NSWindowLevel level, bool interactive)
{
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    w.hasShadow = NO;
    w.level = level;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                           NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    w.acceptsMouseMovedEvents = interactive;
    w.releasedWhenClosed = NO;
    w.contentView = view;
    [w orderFrontRegardless];
    return w;
}

static void close_windows(void)
{
    [g_timer invalidate];
    g_timer = nil;
    for (int i = 0; i < 4; i++) {
        [g_frame[i] orderOut:nil];
        g_frame[i] = nil;
    }
    [g_bar orderOut:nil];
    [g_preview orderOut:nil];
    g_bar = g_preview = nil;
    g_barView = g_previewView = nil;
}

static void teardown(void)
{
    close_windows();
    if (g_hkOK) {
        UnregisterEventHotKey(g_hkEsc);
        UnregisterEventHotKey(g_hkRet);
        g_hkOK = false;
    }
    if (g_hkHandler) {
        RemoveEventHandler(g_hkHandler);
        g_hkHandler = NULL;
    }
    stitch_free(&g_st);
    free(g_thumb);
    g_thumb = NULL;
    g_thumbRows = 0;
    g_thumbCap = 0;
    g_w = g_h = 0;
    g_hover = g_down = -1;
    g_status = nil;
    g_on = false;
}

void long_cancel(void)
{
    if (!g_on)
        return;
    snip_log("long screenshot cancelled at %d rows", stitch_rows(&g_st));
    teardown();
}

void long_finish(bool copy, bool save, bool pin)
{
    if (!g_on)
        return;
    stitch_finish(&g_st);
    int rows = stitch_rows(&g_st);
    if (rows < 1) {
        teardown();
        return;
    }
    CGImageRef img = image_from_bgrx(stitch_canvas(&g_st), g_w, rows, true);
    RECT at = g_rc;
    snip_log("long screenshot done: %dx%d", w_img_w(img), rows);
    teardown(); /* the windows and the canvas are done before any dialog shows */
    if (!img)
        return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (copy && png) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setData:png forType:NSPasteboardTypePNG];
        [pb setData:[rep representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}]
            forType:NSPasteboardTypeTIFF];
    }
    if (save) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp activateIgnoringOtherApps:YES]; /* the page kept the focus; the panel is ours */
#pragma clang diagnostic pop
        NSSavePanel *p = [NSSavePanel savePanel];
        p.allowedContentTypes = @[ UTTypePNG, UTTypeJPEG ];
        p.nameFieldStringValue = @"sniplite-long.png";
        if ([p runModal] == NSModalResponseOK && p.URL)
            [png writeToURL:p.URL atomically:YES];
    }
    if (pin)
        pin_create(img, at.left, at.top > 40 ? at.top - 40 : at.top + 40);
    CGImageRelease(img);
}

bool long_active(void) { return g_on; }

bool long_begin(RECT rc)
{
    if (g_on || rc.right - rc.left < 8 || rc.bottom - rc.top < 8 || !cap_permission())
        return false;
    memset(&g_st, 0, sizeof g_st);
    g_rc = rc;
    g_wpt = rc.right - rc.left;
    g_hpt = rc.bottom - rc.top;
    g_top = 0;
    for (NSScreen *s in [NSScreen screens])
        g_top = MAX(g_top, NSMaxY(s.frame));
    g_on = true;
    g_w = g_h = 0;
    g_thumb = NULL;
    g_thumbRows = 0;
    g_thumbCap = 0;
    g_status = wstr(T(LONG_HINT));
    g_hover = g_down = -1;
    g_pending = false;

    /* the frame: four thin windows, so none of them covers pixels that are being read */
    RECT f[4] = {
        {rc.left - 2, rc.top - 2, rc.right + 2, rc.top},
        {rc.left - 2, rc.bottom, rc.right + 2, rc.bottom + 2},
        {rc.left - 2, rc.top - 2, rc.left, rc.bottom + 2},
        {rc.right, rc.top - 2, rc.right + 2, rc.bottom + 2},
    };
    for (int i = 0; i < 4; i++) {
        NSRect r = NSMakeRect(f[i].left, g_top - f[i].bottom, f[i].right - f[i].left, f[i].bottom - f[i].top);
        NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, r.size.width, r.size.height)];
        v.wantsLayer = YES;
        v.layer.backgroundColor = [NSColor colorWithSRGBRed:(CGFloat)(ACCENT >> 16) / 255.0
                                                     green:(CGFloat)((ACCENT >> 8) & 0xFF) / 255.0
                                                      blue:(CGFloat)(ACCENT & 0xFF) / 255.0
                                                     alpha:0.9]
                                     .CGColor;
        g_frame[i] = make_window(r, v, NSFloatingWindowLevel, false);
    }

    /* where the region is, in Cocoa coordinates, and on which screen */
    NSScreen *screen = [NSScreen mainScreen];
    NSRect regionCocoa = NSMakeRect(rc.left, g_top - rc.bottom, rc.right - rc.left, rc.bottom - rc.top);
    for (NSScreen *s in [NSScreen screens])
        if (NSIntersectsRect(regionCocoa, s.frame)) {
            screen = s;
            break;
        }

    /* the bar: under the region, above it when there is no room */
    CGFloat barX = rc.right - BAR_W;
    if (barX < screen.frame.origin.x + 4)
        barX = screen.frame.origin.x + 4;
    CGFloat barY = regionCocoa.origin.y - GAP - BAR_H;
    if (barY < screen.frame.origin.y + 4)
        barY = NSMaxY(regionCocoa) + GAP;
    LongBarView *bv = [[LongBarView alloc] initWithFrame:NSMakeRect(0, 0, BAR_W, BAR_H)];
    g_barView = bv;
    g_bar = make_window(NSMakeRect(barX, barY, BAR_W, BAR_H), bv, NSFloatingWindowLevel, true);

    /* the preview: beside the region */
    CGFloat pvH = MIN((CGFloat)g_hpt, MIN(520.0, screen.frame.size.height - 16));
    CGFloat pvX = rc.right + GAP;
    if (pvX + PREVIEW_W > NSMaxX(screen.frame))
        pvX = rc.left - GAP - PREVIEW_W;
    if (pvX < screen.frame.origin.x + 4)
        pvX = screen.frame.origin.x + 4;
    CGFloat pvY = g_top - rc.top - pvH;
    if (pvY < screen.frame.origin.y + 4)
        pvY = screen.frame.origin.y + 4;
    LongPreviewView *pv = [[LongPreviewView alloc] initWithFrame:NSMakeRect(0, 0, PREVIEW_W, pvH)];
    g_previewView = pv;
    g_preview = make_window(NSMakeRect(pvX, pvY, PREVIEW_W, pvH), pv, NSFloatingWindowLevel, false);

    /* Esc and Return for the page that keeps the keyboard */
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&on_hotkey, 1, &spec, NULL, &g_hkHandler);
    EventHotKeyID esc = {'SNLG', 1}, ret = {'SNLG', 2};
    g_hkOK = RegisterEventHotKey(kVK_Escape, 0, esc, GetApplicationEventTarget(), 0, &g_hkEsc) == noErr;
    g_hkOK = RegisterEventHotKey(kVK_Return, 0, ret, GetApplicationEventTarget(), 0, &g_hkRet) == noErr && g_hkOK;

    if (!g_pump)
        g_pump = [LongPump new];
    g_timer = [NSTimer scheduledTimerWithTimeInterval:TICK_S
                                              target:g_pump
                                            selector:@selector(fire:)
                                            userInfo:nil
                                             repeats:YES];
    snip_log("long screenshot: region %ld,%ld %dx%d, hotkeys %s", (long)rc.left, (long)rc.top, g_wpt, g_hpt,
             g_hkOK ? "ok" : "unavailable");
    update_ui();
    return true;
}