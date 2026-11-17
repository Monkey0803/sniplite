/* overlay.m: the capture overlay of the macOS port.
 *
 * One borderless window per display at CGShieldingWindowLevel (menu bar, Dock and all
 * Spaces included), showing the frozen frame of that display. Two phases, as in the
 * Windows overlay (src/ov_show.S):
 *
 *   select  the desktop dimmed, the window under the cursor lit up, a magnifier with the
 *           pixel under the cursor, a drag that picks the area; a click picks a window.
 *   edit    the selection lit up with its eight handles, the toolbar under it, the
 *           annotations of src/ov_edit.S (nine tools, colours, three sizes, undo/redo),
 *           an inline text field for the text tool (so an input method works), and the
 *           output keys: Enter copies, Cmd+S saves, Cmd+T pins, Esc leaves.
 *
 * Why one window per display and not one over the union: AppKit constrains a window's
 * frame to the screen it is ordered onto (measured in Phase 2), and each display has its
 * own scale. A selection therefore stays on the display the drag started on.
 *
 * Drawing: the dimmed display is one pre-composited image per window; the lit regions are
 * the original tiles through a clip; annotations are Core Graphics paths (draw_cg.c,
 * annotate.m) so the screen and the copied image go through the same code. */
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <string.h>

#include "annotate.h"
#include "capture.h"
#include "common.h"
#include "draw_cg.h"
#include "icons.h"
#include "lang.h"
#include "longscreen.h"
#include "output.h"
#include "overlay.h"
#include "pin.h"
#include "ov_layout.inc" /* ACCENT, MAG_COLS, MAG_ROWS, T_*, B_* */
#include "plat.h"
#include "toolbar.h"

#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif

#define MAG_CELL 10.0
#define HL_BORDER 1.5
#define SEL_BORDER 1.0
#define HANDLE 7.0

static void clear_other_selections(NSView *keep);

static void activate_app(void);

static SnipShot g_shot;
static bool g_active;
static double g_t0;                    /* when the hotkey asked for the overlay */
static NSRunningApplication *g_prev;   /* the app that had the focus before the overlay */
static unsigned g_gen;
static NSMutableArray *g_windows;
static NSView *g_activeView;
static NSView *g_selView;

/* ---- text ---------------------------------------------------------------------------- */

static bool ui_zh(void)
{
    int l = lang_choice();
    if (l == LG_AUTO)
        l = lang_system();
    return l == LG_ZH_CN || l == LG_ZH_TW;
}

static NSString *tr(NSString *en, NSString *zh) { return ui_zh() ? zh : en; }

/* ---- colours ------------------------------------------------------------------------- */

static void rgbv(int c, CGFloat *r, CGFloat *g, CGFloat *b)
{
    *r = (CGFloat)((c >> 16) & 0xFF) / 255.0;
    *g = (CGFloat)((c >> 8) & 0xFF) / 255.0;
    *b = (CGFloat)(c & 0xFF) / 255.0;
}

static NSColor *accent(void)
{
    CGFloat r, g, b;
    rgbv(ACCENT, &r, &g, &b);
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

static NSDictionary *label_attrs(void)
{
    return @{
        NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : [NSColor whiteColor],
    };
}

static void fill_rect(CGContextRef cg, CGRect r, NSColor *c)
{
    CGContextSetFillColorWithColor(cg, c.CGColor);
    CGContextFillRect(cg, r);
}

/* The views are flipped, so a CGImage drawn straight into one comes out upside down:
 * flip around the rect's top edge so the image's first row lands at the top. */
static void draw_image_topdown(CGContextRef cg, CGRect r, CGImageRef img)
{
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, CGRectGetMinX(r), CGRectGetMaxY(r));
    CGContextScaleCTM(cg, 1, -1);
    CGContextDrawImage(cg, CGRectMake(0, 0, r.size.width, r.size.height), img);
    CGContextRestoreGState(cg);
}

static void stroke_rect(CGContextRef cg, CGRect r, NSColor *c, CGFloat w)
{
    CGContextSetStrokeColorWithColor(cg, c.CGColor);
    CGContextSetLineWidth(cg, w);
    CGContextStrokeRect(cg, CGRectInset(r, w / 2, w / 2));
}

static void rounded_fill(CGContextRef cg, CGRect r, CGFloat radius, uint32_t rgb, int alpha)
{
    CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    CGContextSetFillColorWithColor(cg, [NSColor colorWithSRGBRed:(CGFloat)((rgb >> 16) & 0xFF) / 255.0
                                                          green:(CGFloat)((rgb >> 8) & 0xFF) / 255.0
                                                           blue:(CGFloat)(rgb & 0xFF) / 255.0
                                                          alpha:(CGFloat)alpha / 255.0]
                                        .CGColor);
    CGContextAddPath(cg, path);
    CGContextFillPath(cg);
    CGPathRelease(path);
}

/* ---- the overlay window --------------------------------------------------------------- */

@interface SnipOverlayWindow : NSWindow
@end

@implementation SnipOverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface SnipOverlayView : NSView
- (instancetype)initWithShot:(const SnipShot *)shot rect:(RECT)rc;
- (void)start;
- (void)teardown;
- (void)becomeKey;
- (void)copySelection;
- (void)clearSelection;
- (void)beginLong;
- (void)demoSelection;
@end

@interface SnipOverlayView () <NSTextFieldDelegate> {
    SnipShot _shot;
    RECT _rc;
    CGRect _bounds;
    CGImageRef *_tileImage;
    CGImageRef _dim;
    RECT *_cand;
    int _ncand, _candAt;
    RECT _hl, _sel, _sel0;
    POINT _anchor, _cursor;
    CGPoint _mouse;
    bool _dragging, _hasSel, _highlight, _inside;
    NSTrackingArea *_track;

    AnnoList *_anno;
    AnnoHist _hist;
    Tb _tb;
    int _drawIdx;
    int _dragKind; /* 0 none, 1 move the selection, 2 resize it, 3 draw */
    int _edges;
    int _num;
    NSTextField *_field;
    CGPoint _textPoint;
    int _textSize;
    uint32_t _textColor;
    bool _typing;
    bool _cancelled;
    NSString *_notice;
    NSTimer *_noticeTimer;
}
@end

enum { DRAG_NONE, DRAG_MOVE, DRAG_RESIZE, DRAG_DRAW };

@implementation SnipOverlayView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (instancetype)initWithShot:(const SnipShot *)shot rect:(RECT)rc
{
    CGRect bounds = CGRectMake(0, 0, rc.right - rc.left, rc.bottom - rc.top);
    self = [super initWithFrame:bounds];
    if (!self)
        return nil;
    _bounds = bounds;
    _rc = rc;
    _shot = *shot;
    _num = 1;
    _drawIdx = -1;
    _tileImage = calloc((size_t)MAX(1, _shot.ntile), sizeof(CGImageRef));
    for (int i = 0; i < _shot.ntile; i++) {
        const SnipTile *t = &_shot.tile[i];
        CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, t->px, (size_t)t->w * (size_t)t->h * 4, NULL);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        _tileImage[i] = CGImageCreate((size_t)t->w, (size_t)t->h, 8, 32, (size_t)t->w * 4, cs,
                                      kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, prov, NULL, false,
                                      kCGRenderingIntentDefault);
        CGColorSpaceRelease(cs);
        CGDataProviderRelease(prov);
    }
    _anno = anno_list_new();
    anno_hist_init(&_hist, _anno);
    _tb.tool = T_NONE;
    _tb.color = 0xE53935;
    _tb.size = 0;
    [self build_dim];
    return self;
}

- (void)teardown
{
    [self dismissField];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_noticeTimer invalidate];
    _noticeTimer = nil;
    for (int i = 0; i < _shot.ntile; i++)
        if (_tileImage && _tileImage[i]) {
            CGImageRelease(_tileImage[i]);
            _tileImage[i] = NULL;
        }
    if (_dim) {
        CGImageRelease(_dim);
        _dim = NULL;
    }
    free(_tileImage);
    _tileImage = NULL;
    free(_cand);
    _cand = NULL;
    _ncand = 0;
    anno_list_free(_anno);
    _anno = NULL;
    anno_hist_free(&_hist);
    memset(&_shot, 0, sizeof _shot);
}

- (void)dealloc
{
    [self teardown];
}

/* Compose the tiles that intersect this display at this display's scale, then dim it. */
- (void)build_dim
{
    CGFloat s = 1;
    for (int i = 0; i < _shot.ntile; i++)
        if (CGRectIntersectsRect([self local_rect:_shot.tile[i].rc], _bounds))
            s = MAX(s, (CGFloat)_shot.tile[i].scale);
    int w = (int)lround(_bounds.size.width * s), h = (int)lround(_bounds.size.height * s);
    if (w < 1 || h < 1)
        return;
    uint32_t *px = calloc((size_t)w * (size_t)h, 4);
    if (!px)
        return;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(px, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!cg) {
        free(px);
        return;
    }
    CGContextScaleCTM(cg, s, s);
    fill_rect(cg, _bounds, [NSColor blackColor]);
    for (int i = 0; i < _shot.ntile; i++) {
        CGRect r = [self local_rect:_shot.tile[i].rc];
        if (!_tileImage[i] || !CGRectIntersectsRect(r, _bounds))
            continue;
        CGContextDrawImage(cg, r, _tileImage[i]);
    }
    fill_rect(cg, _bounds, [NSColor colorWithCalibratedWhite:0 alpha:0.45]);
    _dim = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    free(px);
}

/* ---- geometry ------------------------------------------------------------------------- */

- (CGRect)local_rect:(RECT)r
{
    return CGRectMake((CGFloat)(r.left - _rc.left), (CGFloat)(r.top - _rc.top), (CGFloat)(r.right - r.left),
                      (CGFloat)(r.bottom - r.top));
}

- (CGRect)local_norm:(RECT)r
{
    RECT n = {MIN(r.left, r.right), MIN(r.top, r.bottom), MAX(r.left, r.right), MAX(r.top, r.bottom)};
    return [self local_rect:n];
}

- (void)draw_tiles_in:(CGContextRef)cg clip:(CGRect)clip
{
    CGContextSaveGState(cg);
    CGContextClipToRect(cg, clip);
    for (int i = 0; i < _shot.ntile; i++) {
        CGRect r = [self local_rect:_shot.tile[i].rc];
        if (!_tileImage[i] || !CGRectIntersectsRect(r, clip))
            continue;
        draw_image_topdown(cg, r, _tileImage[i]);
    }
    CGContextRestoreGState(cg);
}

/* ---- windows under the cursor ---------------------------------------------------------- */

- (void)refresh_cands
{
    if (!_inside)
        return;
    RECT found[16];
    int n = cap_windows_at(_cursor.x, _cursor.y, found, (int)(sizeof found / sizeof found[0]));
    free(_cand);
    _cand = NULL;
    _ncand = 0;
    _highlight = false;
    if (n <= 0)
        return;
    _cand = calloc((size_t)n, sizeof *found);
    if (!_cand)
        return;
    memcpy(_cand, found, (size_t)n * sizeof *found);
    _ncand = n;
    if (_candAt >= n)
        _candAt = 0;
    _hl = _cand[_candAt];
    _highlight = true;
}

- (void)cycle_cands:(int)dir
{
    if (_ncand <= 0)
        return;
    _candAt = (_candAt + (_ncand + dir)) % _ncand;
    _hl = _cand[_candAt];
    _highlight = true;
    [self setNeedsDisplay:YES];
}

/* ---- toolbar --------------------------------------------------------------------------- */

- (RECT)sel_local
{
    return (RECT){_sel.left - _rc.left, _sel.top - _rc.top, _sel.right - _rc.left, _sel.bottom - _rc.top};
}

- (void)layout_toolbar
{
    _tb.can_undo = anno_hist_can_undo(&_hist);
    _tb.can_redo = anno_hist_can_redo(&_hist);
    tb_layout(&_tb, [self sel_local], _bounds);
}

- (void)showNotice:(NSString *)text
{
    _notice = text;
    [_noticeTimer invalidate];
    _noticeTimer = [NSTimer scheduledTimerWithTimeInterval:1.8
                                                    target:self
                                                  selector:@selector(clearNotice:)
                                                  userInfo:nil
                                                   repeats:NO];
    [self setNeedsDisplay:YES];
}

- (void)clearNotice:(NSTimer *)t
{
    (void)t;
    _notice = nil;
    _noticeTimer = nil;
    [self setNeedsDisplay:YES];
}

/* ---- handles --------------------------------------------------------------------------- */

/* The eight handles of the selection, in view-local points. */
- (void)handle_rects:(CGRect *)out
{
    CGRect s = [self local_rect:_sel];
    CGFloat h = HANDLE / 2;
    out[0] = CGRectMake(s.origin.x - h, s.origin.y - h, HANDLE, HANDLE);                          /* nw */
    out[1] = CGRectMake(CGRectGetMidX(s) - h, s.origin.y - h, HANDLE, HANDLE);                    /* n  */
    out[2] = CGRectMake(CGRectGetMaxX(s) - h, s.origin.y - h, HANDLE, HANDLE);                    /* ne */
    out[3] = CGRectMake(CGRectGetMaxX(s) - h, CGRectGetMidY(s) - h, HANDLE, HANDLE);               /* e  */
    out[4] = CGRectMake(CGRectGetMaxX(s) - h, CGRectGetMaxY(s) - h, HANDLE, HANDLE);               /* se */
    out[5] = CGRectMake(CGRectGetMidX(s) - h, CGRectGetMaxY(s) - h, HANDLE, HANDLE);               /* s  */
    out[6] = CGRectMake(s.origin.x - h, CGRectGetMaxY(s) - h, HANDLE, HANDLE);                     /* sw */
    out[7] = CGRectMake(s.origin.x - h, CGRectGetMidY(s) - h, HANDLE, HANDLE);                     /* w  */
}

- (int)handle_at:(CGPoint)p
{
    if (!_hasSel)
        return 0;
    CGRect h[8];
    [self handle_rects:h];
    for (int i = 0; i < 8; i++)
        if (CGRectContainsPoint(CGRectInset(h[i], -2, -2), p))
            return i + 1;
    return 0;
}

static int edges_of_handle(int h)
{
    switch (h) {
    case 1: return EDGE_L | EDGE_T;
    case 2: return EDGE_T;
    case 3: return EDGE_R | EDGE_T;
    case 4: return EDGE_R;
    case 5: return EDGE_R | EDGE_B;
    case 6: return EDGE_B;
    case 7: return EDGE_L | EDGE_B;
    case 8: return EDGE_L;
    default: return 0;
    }
}

/* ---- annotations ----------------------------------------------------------------------- */

- (void)pushHistory { anno_hist_push(&_hist, _anno); }

- (void)undo
{
    const AnnoList *s = anno_hist_undo(&_hist);
    if (!s)
        return;
    anno_list_free(_anno);
    _anno = anno_list_clone(s);
    [self setNeedsDisplay:YES];
}

- (void)redo
{
    const AnnoList *s = anno_hist_redo(&_hist);
    if (!s)
        return;
    anno_list_free(_anno);
    _anno = anno_list_clone(s);
    [self setNeedsDisplay:YES];
}

- (void)deleteLast
{
    if (!_anno || !_anno->n)
        return;
    SnipAnno *a = &_anno->a[--_anno->n];
    free(a->pt);
    free(a->text);
    memset(a, 0, sizeof *a);
    [self pushHistory];
    [self setNeedsDisplay:YES];
}

/* selection-local point of a global point, clamped into the selection */
- (CGPoint)local_sel:(POINT)g
{
    double x = g.x - _sel.left, y = g.y - _sel.top;
    x = fmax(0, fmin(x, _sel.right - _sel.left));
    y = fmax(0, fmin(y, _sel.bottom - _sel.top));
    return CGPointMake(x, y);
}

- (void)dismissField
{
    if (_field) {
        [_field removeFromSuperview];
        _field = nil;
    }
    _typing = false;
}

- (void)beginTextAt:(CGPoint)local color:(uint32_t)color size:(int)size
{
    [self dismissField];
    _typing = true;
    _field = [[NSTextField alloc] initWithFrame:NSMakeRect(local.x, local.y, 240, anno_font[size] + 10)];
    _field.font = [NSFont systemFontOfSize:anno_font[size]];
    _field.textColor = [NSColor colorWithSRGBRed:(CGFloat)((color >> 16) & 0xFF) / 255.0
                                           green:(CGFloat)((color >> 8) & 0xFF) / 255.0
                                            blue:(CGFloat)(color & 0xFF) / 255.0
                                           alpha:1.0];
    _field.drawsBackground = NO;
    _field.bezeled = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.delegate = self;
    _field.placeholderString = tr(@"type, Enter to place", @"输入文字，回车放置");
    _field.cell.usesSingleLineMode = YES;
    _field.target = self;
    _field.action = @selector(fieldCommit:);
    [self addSubview:_field];
    [self.window makeFirstResponder:_field];
    _textPoint = local;
    _textSize = size;
    _textColor = color;
    [self setNeedsDisplay:YES];
}

- (void)fieldCommit:(id)sender
{
    (void)sender;
    [self commitField];
}

- (void)commitField
{
    if (!_field || _cancelled) {
        [self dismissField];
        return;
    }
    NSString *s = _field.stringValue;
    [self dismissField];
    if (s.length) {
        anno_add_text(_anno, _textColor, _textSize, _textPoint, s.UTF8String);
        [self pushHistory];
    }
    [self.window makeFirstResponder:self];
    [self setNeedsDisplay:YES];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)sel
{
    (void)control;
    (void)tv;
    if (sel == @selector(insertNewline:)) {
        [self commitField];
        return YES;
    }
    if (sel == @selector(cancelOperation:)) {
        _cancelled = true;
        [self dismissField];
        _cancelled = false;
        [self.window makeFirstResponder:self];
        [self setNeedsDisplay:YES];
        return YES;
    }
    return NO;
}

/* ---- drawing ---------------------------------------------------------------------------- */

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
    if (!cg)
        return;

    if (_dim)
        draw_image_topdown(cg, _bounds, _dim);
    else
        fill_rect(cg, _bounds, [NSColor blackColor]);

    bool active = (g_activeView == self);

    if (_hasSel) {
        CGRect sr = [self local_rect:_sel];
        [self draw_tiles_in:cg clip:sr];
        /* annotations in their own space, clipped to the selection */
        CGContextSaveGState(cg);
        CGContextClipToRect(cg, sr);
        CGContextTranslateCTM(cg, (CGFloat)(_sel.left - _rc.left), (CGFloat)(_sel.top - _rc.top));
        anno_render(cg, _anno, &_shot, _sel);
        CGContextRestoreGState(cg);
        stroke_rect(cg, sr, accent(), SEL_BORDER);
        [self draw_handles:cg];
        [self draw_size_label:cg rect:sr
                          text:[NSString stringWithFormat:@"%ld × %ld", (long)(_sel.right - _sel.left),
                                                          (long)(_sel.bottom - _sel.top)]];
        [self layout_toolbar];
        tb_draw(cg, &_tb);
    } else if (_highlight && active) {
        CGRect hr = [self local_norm:_hl];
        [self draw_tiles_in:cg clip:hr];
        stroke_rect(cg, hr, accent(), HL_BORDER);
        [self draw_size_label:cg rect:hr
                          text:[NSString stringWithFormat:@"%ld × %ld", (long)(_hl.right - _hl.left),
                                                          (long)(_hl.bottom - _hl.top)]];
    }

    if (_dragging && !_hasSel) { /* rubber band while picking */
        CGRect sr = [self local_norm:_sel];
        if (sr.size.width >= 1 && sr.size.height >= 1) {
            [self draw_tiles_in:cg clip:sr];
            stroke_rect(cg, sr, accent(), SEL_BORDER);
            [self draw_size_label:cg rect:sr
                              text:[NSString stringWithFormat:@"%ld × %ld", (long)lround(sr.size.width),
                                                              (long)lround(sr.size.height)]];
        }
    }

    if (!_hasSel) {
        NSColor *line = [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.55];
        CGContextSetStrokeColorWithColor(cg, line.CGColor);
        CGContextSetLineWidth(cg, 1.0);
        CGContextMoveToPoint(cg, 0, _mouse.y + 0.5);
        CGContextAddLineToPoint(cg, _bounds.size.width, _mouse.y + 0.5);
        CGContextMoveToPoint(cg, _mouse.x + 0.5, 0);
        CGContextAddLineToPoint(cg, _mouse.x + 0.5, _bounds.size.height);
        CGContextStrokePath(cg);
        [self draw_magnifier:cg];
    }

    if (_notice) {
        NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:13],
                                NSForegroundColorAttributeName : [NSColor whiteColor]};
        NSSize ts = [_notice sizeWithAttributes:attrs];
        double w = ts.width + 28, h = 34;
        CGRect box = CGRectMake((_bounds.size.width - w) / 2, 24, w, h);
        rounded_fill(cg, box, 9, 0x000000, 235);
        [_notice drawAtPoint:NSMakePoint(box.origin.x + 14, box.origin.y + 9) withAttributes:attrs];
    }
}

- (void)draw_handles:(CGContextRef)cg
{
    if (!_hasSel)
        return;
    CGRect h[8];
    [self handle_rects:h];
    for (int i = 0; i < 8; i++) {
        fill_rect(cg, h[i], [NSColor whiteColor]);
        stroke_rect(cg, h[i], accent(), 1.0);
    }
}

- (void)draw_size_label:(CGContextRef)cg rect:(CGRect)r text:(NSString *)text
{
    NSDictionary *attrs = label_attrs();
    NSSize ts = [text sizeWithAttributes:attrs];
    CGFloat w = ts.width + 12, h = ts.height + 6;
    CGFloat x = CGRectGetMaxX(r) - w - 4, y = CGRectGetMaxY(r) + 4;
    if (y + h > _bounds.size.height)
        y = CGRectGetMaxY(r) - h - 4;
    if (x < 0)
        x = 4;
    if (y < 0)
        y = 4;
    CGRect box = CGRectMake(x, y, w, h);
    CGPathRef path = CGPathCreateWithRoundedRect(box, 3, 3, NULL);
    CGContextSaveGState(cg);
    CGContextSetFillColorWithColor(cg, accent().CGColor);
    CGContextAddPath(cg, path);
    CGContextFillPath(cg);
    CGContextRestoreGState(cg);
    CGPathRelease(path);
    [text drawAtPoint:NSMakePoint(x + 6, y + 3) withAttributes:attrs];
}

- (void)draw_magnifier:(CGContextRef)cg
{
    int cols = MAG_COLS, rows = MAG_ROWS;
    CGRect grid = CGRectMake(0, 0, cols * MAG_CELL, rows * MAG_CELL);
    CGFloat x = _mouse.x + 18, y = _mouse.y + 18;
    if (x + grid.size.width + 12 > _bounds.size.width)
        x = _mouse.x - grid.size.width - 18;
    if (y + grid.size.height + 34 > _bounds.size.height)
        y = _mouse.y - grid.size.height - 34;
    if (x < 0)
        x = 0;
    if (y < 0)
        y = 0;
    grid.origin = CGPointMake(x, y);

    CGContextSaveGState(cg);
    CGRect panel = CGRectInset(grid, -6, -6);
    panel.size.height += 22;
    CGContextSetFillColorWithColor(cg, [NSColor colorWithCalibratedWhite:0.08 alpha:0.92].CGColor);
    CGPathRef path = CGPathCreateWithRoundedRect(panel, 6, 6, NULL);
    CGContextAddPath(cg, path);
    CGContextFillPath(cg);
    CGPathRelease(path);

    const SnipTile *t = NULL;
    for (int i = 0; i < _shot.ntile; i++)
        if (rect_has(&_shot.tile[i].rc, _cursor.x, _cursor.y)) {
            t = &_shot.tile[i];
            break;
        }
    uint32_t center = 0xFF000000u;
    int half_c = cols / 2, half_r = rows / 2;
    for (int r = 0; r < rows; r++)
        for (int c = 0; c < cols; c++) {
            int gx = _cursor.x + (c - half_c), gy = _cursor.y + (r - half_r);
            uint32_t px = 0xFF000000u;
            if (t && rect_has(&t->rc, gx, gy)) {
                int sx = (int)lround((gx - t->rc.left) * t->scale);
                int sy = (int)lround((gy - t->rc.top) * t->scale);
                if (sx >= 0 && sy >= 0 && sx < t->w && sy < t->h)
                    px = t->px[(size_t)sy * (size_t)t->w + (size_t)sx];
            }
            if (c == half_c && r == half_r)
                center = px;
            CGFloat rr = (CGFloat)((px >> 16) & 0xFF) / 255.0, gg = (CGFloat)((px >> 8) & 0xFF) / 255.0,
                    bb = (CGFloat)(px & 0xFF) / 255.0;
            fill_rect(cg, CGRectMake(grid.origin.x + c * MAG_CELL, grid.origin.y + r * MAG_CELL, MAG_CELL, MAG_CELL),
                      [NSColor colorWithSRGBRed:rr green:gg blue:bb alpha:1.0]);
        }
    stroke_rect(cg,
                CGRectMake(grid.origin.x + half_c * MAG_CELL, grid.origin.y + half_r * MAG_CELL, MAG_CELL, MAG_CELL),
                [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.9], 1.0);

    NSString *hex = [NSString stringWithFormat:@"#%06X  %d, %d", center & 0xFFFFFF, _cursor.x, _cursor.y];
    [hex drawAtPoint:NSMakePoint(grid.origin.x + 2, CGRectGetMaxY(grid) + 3)
      withAttributes:@{
          NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
          NSForegroundColorAttributeName : [NSColor whiteColor],
      }];
    CGContextRestoreGState(cg);
}

/* ---- events ----------------------------------------------------------------------------- */

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (_track)
        [self removeTrackingArea:_track];
    _track = [[NSTrackingArea alloc] initWithRect:self.bounds
                                          options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                  NSTrackingActiveAlways | NSTrackingInVisibleRect
                                            owner:self
                                         userInfo:nil];
    [self addTrackingArea:_track];
}

- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:[NSCursor crosshairCursor]];
}

- (void)becomeKey
{
    if (!self.window || self.window.keyWindow)
        return;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self];
}

- (POINT)global_point:(NSEvent *)e
{
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _mouse = CGPointMake(p.x, p.y);
    POINT g = {(LONG)floor(p.x) + _rc.left, (LONG)floor(p.y) + _rc.top};
    return g;
}

- (void)mouseEntered:(NSEvent *)e
{
    _inside = true;
    g_activeView = self;
    [self becomeKey];
    POINT p = [self global_point:e];
    _cursor = p;
    [self refresh_cands];
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)e
{
    (void)e;
    _inside = false;
    if (g_activeView == self)
        g_activeView = nil;
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)e
{
    _inside = true;
    g_activeView = self;
    POINT last = _cursor;
    _cursor = [self global_point:e];

    if (_hasSel) {
        [self layout_toolbar];
        int hover = _typing ? 0 : tb_hit(&_tb, _mouse);
        if (hover != _tb.hover) {
            _tb.hover = hover;
            [self setNeedsDisplay:YES];
        }
        return;
    }
    if (_cursor.x != last.x || _cursor.y != last.y) {
        [self refresh_cands];
        [self setNeedsDisplay:YES];
    }
}

- (void)startSelectionAt:(POINT)g
{
    [self dismissField];
    clear_other_selections(self);
    if (_anno) {
        anno_list_free(_anno);
        _anno = anno_list_new();
        anno_hist_free(&_hist);
        anno_hist_init(&_hist, _anno);
    }
    _num = 1;
    _hasSel = false;
    _anchor = g;
    _cursor = g;
    _sel = (RECT){g.x, g.y, g.x, g.y};
    _dragging = true;
    _dragKind = DRAG_NONE;
}

- (void)mouseDown:(NSEvent *)e
{
    if (_typing) {
        [self commitField];
        return;
    }
    g_activeView = self;
    [self becomeKey];
    POINT g = [self global_point:e];

    if (_hasSel) {
        [self layout_toolbar];
        if (_tb.palette) {
            int hit = tb_palette_hit(&_tb, _mouse);
            if (hit >= 0) {
                if (hit < 100)
                    _tb.color = tb_palette[hit];
                else
                    _tb.size = hit - 100;
                _tb.palette = false;
                [self setNeedsDisplay:YES];
                return;
            }
            _tb.palette = false;
            [self setNeedsDisplay:YES];
        }
        int id = tb_hit(&_tb, _mouse);
        if (id) {
            [self button:id];
            return;
        }
        int h = [self handle_at:_mouse];
        if (h) {
            _dragKind = DRAG_RESIZE;
            _edges = edges_of_handle(h);
            _sel0 = _sel;
            _anchor = g;
            return;
        }
        if (_tb.tool != T_NONE) {
            CGPoint lp = [self local_sel:g];
            if (_tb.tool == T_TEXT) {
                [self beginTextAt:lp color:_tb.color size:_tb.size];
                return;
            }
            if (_tb.tool == T_NUMBER) {
                anno_add_number(_anno, _tb.color, _tb.size, lp, _num++);
                [self pushHistory];
                [self setNeedsDisplay:YES];
                return;
            }
            _drawIdx = anno_begin(_anno, _tb.tool, _tb.color, _tb.size, lp);
            _dragKind = DRAG_DRAW;
            return;
        }
        if (rect_has(&_sel, (int)g.x, (int)g.y)) {
            _dragKind = DRAG_MOVE;
            _sel0 = _sel;
            _anchor = g;
            return;
        }
    }
    [self startSelectionAt:g];
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)e
{
    POINT g = [self global_point:e];
    if (_hasSel) {
        switch (_dragKind) {
        case DRAG_MOVE: {
            LONG dx = g.x - _anchor.x, dy = g.y - _anchor.y;
            _sel = _sel0;
            _sel.left += dx;
            _sel.right += dx;
            _sel.top += dy;
            _sel.bottom += dy;
            _sel = rect_isect(_sel, _rc);
            [self setNeedsDisplay:YES];
            return;
        }
        case DRAG_RESIZE: {
            RECT r = _sel0;
            /* inclusive corners, like rect_corners: the pixel under the pointer is in */
            if (_edges & EDGE_L)
                r.left = MIN(g.x, r.right - 4);
            if (_edges & EDGE_R)
                r.right = MAX(g.x + 1, r.left + 4);
            if (_edges & EDGE_T)
                r.top = MIN(g.y, r.bottom - 4);
            if (_edges & EDGE_B)
                r.bottom = MAX(g.y + 1, r.top + 4);
            _sel = rect_isect(r, _rc);
            [self setNeedsDisplay:YES];
            return;
        }
        case DRAG_DRAW: {
            if (_drawIdx >= 0) {
                anno_drag(_anno, _drawIdx, [self local_sel:g]);
                [self setNeedsDisplay:YES];
            }
            return;
        }
        default:
            break;
        }
    }
    _cursor = g;
    _cursor.x = CLAMPI(_cursor.x, _rc.left, _rc.right - 1);
    _cursor.y = CLAMPI(_cursor.y, _rc.top, _rc.bottom - 1);
    _sel = rect_corners(_anchor, _cursor);
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e
{
    (void)e;
    if (_hasSel) {
        if (_dragKind == DRAG_DRAW && _drawIdx >= 0) {
            anno_end(_anno, _drawIdx);
            const SnipAnno *a = anno_at(_anno, _drawIdx);
            double w = a && a->npt > 1 ? fabs(a->pt[1].x - a->pt[0].x) : 0;
            double h = a && a->npt > 1 ? fabs(a->pt[1].y - a->pt[0].y) : 0;
            if (a && (a->tool == T_PEN ? a->npt < 2 : w < 3 || h < 3) && a->tool != T_LINE && a->tool != T_ARROW) {
                /* a stray click: drop it rather than leave an invisible annotation */
                _anno->n--;
                free(a->pt);
                free(a->text);
            } else {
                [self pushHistory];
            }
            _drawIdx = -1;
        }
        _dragKind = DRAG_NONE;
        [self setNeedsDisplay:YES];
        return;
    }
    if (!_dragging)
        return;
    _dragging = false;
    RECT r = rect_corners(_anchor, _cursor);
    if (r.right - r.left < 4 || r.bottom - r.top < 4) {
        _highlight = false;
        [self refresh_cands];
        if (_highlight)
            r = _hl;
        else
            r = (RECT){_anchor.x, _anchor.y, _anchor.x + 1, _anchor.y + 1};
    }
    r = rect_isect(r, _rc);
    _sel = r;
    _hasSel = !rect_empty(&r);
    if (_hasSel)
        g_selView = self;
    snip_log("selection %ld,%ld %ldx%ld%s", (long)r.left, (long)r.top, (long)(r.right - r.left),
             (long)(r.bottom - r.top), _hasSel ? "" : " (empty)");
    [self setNeedsDisplay:YES];
}

- (void)button:(int)id
{
    switch (id) {
    case B_UNDO:
        [self undo];
        return;
    case B_REDO:
        [self redo];
        return;
    case B_COLOR:
        _tb.palette = !_tb.palette;
        [self setNeedsDisplay:YES];
        return;
    case B_SIZE:
        _tb.palette = !_tb.palette;
        [self setNeedsDisplay:YES];
        return;
    case B_OK:
        [self copySelection];
        return;
    case B_CLOSE:
        ov_cancel();
        return;
    case B_SAVE:
        [self saveImage];
        return;
    case B_PIN:
        [self pinImage];
        return;
    case B_LONG:
        [self beginLong];
        return;
    case B_OCR:
    case B_OCRCOPY:
        [self showNotice:tr(@"Text recognition is not installed", @"文字识别模块未安装")];
        return;
    default:
        if (id >= T_RECT && id <= T_NUMBER)
            _tb.tool = _tb.tool == id ? T_NONE : id;
        [self setNeedsDisplay:YES];
        return;
    }
}

- (void)otherMouseDown:(NSEvent *)e
{
    if (e.buttonNumber == 2 && _hasSel) /* middle click pins, as on Windows */
        [self pinImage];
}

- (void)scrollWheel:(NSEvent *)e
{
    if (!_hasSel && _ncand > 0)
        [self cycle_cands:e.scrollingDeltaY < 0 ? -1 : 1];
}

- (void)rightMouseDown:(NSEvent *)e
{
    (void)e;
    ov_cancel();
}

- (void)keyDown:(NSEvent *)e
{
    bool cmd = (e.modifierFlags & NSEventModifierFlagCommand) != 0;
    bool shift = (e.modifierFlags & NSEventModifierFlagShift) != 0;
    if (cmd && e.keyCode == 6) { /* Cmd+Z */
        if (shift)
            [self redo];
        else
            [self undo];
        return;
    }
    if (cmd && e.keyCode == 1) { /* Cmd+S */
        [self saveImage];
        return;
    }
    if (cmd && e.keyCode == 17) { /* Cmd+T */
        [self pinImage];
        return;
    }
    if (cmd && e.keyCode == 37) { /* Cmd+L: the long screenshot */
        if (_hasSel)
            [self beginLong];
        return;
    }
    if (cmd && e.keyCode == 8) { /* Cmd+C */
        if (_hasSel)
            [self copySelection];
        return;
    }
    switch (e.keyCode) {
    case 53: /* Esc */
        if (_tb.palette) {
            _tb.palette = false;
            [self setNeedsDisplay:YES];
            return;
        }
        if (_hasSel) {
            [self clearSelection];
            return;
        }
        ov_cancel();
        return;
    case 36: /* Return */
    case 76: /* Enter */
        if (_hasSel)
            [self copySelection];
        else if (g_selView)
            [(SnipOverlayView *)g_selView copySelection];
        return;
    case 51: /* Backspace */
    case 117: /* forward delete */
        [self deleteLast];
        return;
    case 123: /* left */
    case 124: /* right */
    case 125: /* down */
    case 126: /* up */
        if (_hasSel) {
            int d = shift ? 10 : 1;
            RECT r = _sel;
            if (e.keyCode == 123) {
                r.left -= d;
                r.right -= d;
            } else if (e.keyCode == 124) {
                r.left += d;
                r.right += d;
            } else if (e.keyCode == 126) {
                r.top -= d;
                r.bottom -= d;
            } else {
                r.top += d;
                r.bottom += d;
            }
            _sel = rect_isect(r, _rc);
            [self setNeedsDisplay:YES];
        }
        return;
    default:
        break;
    }
    { /* 1..9 pick a tool; the ANSI key codes are not sequential */
        static const struct {
            unsigned short key;
            int tool;
        } keys[] = {{18, T_RECT}, {19, T_ELLIPSE}, {20, T_LINE}, {21, T_ARROW}, {23, T_PEN},
                    {22, T_MARKER}, {26, T_MOSAIC}, {28, T_TEXT}, {25, T_NUMBER}};
        for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
            if (e.keyCode == keys[i].key && _hasSel) {
                _tb.tool = keys[i].tool;
                [self setNeedsDisplay:YES];
                return;
            }
    }
    [super keyDown:e];
}

/* The selection with its annotations, off the frozen frame: what copy, save and pin use. */
- (CGImageRef)newRenderedImage CF_RETURNS_RETAINED
{
    if (!_hasSel)
        return NULL;
    return out_crop_annotated(&_shot, _sel, _anno);
}

- (void)saveImage
{
    CGImageRef img = [self newRenderedImage];
    if (!img)
        return;
    RECT sel = _sel;
    ov_cancel(); /* the shield window would cover the save dialog */
    activate_app(); /* the panel belongs to this app, which may have lost the focus */
    NSSavePanel *p = [NSSavePanel savePanel];
    p.allowedContentTypes = @[ UTTypePNG, UTTypeJPEG ];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    p.nameFieldStringValue = [NSString stringWithFormat:@"sniplite_%@.png", [f stringFromDate:[NSDate date]]];
    if ([p runModal] == NSModalResponseOK && p.URL) {
        if (out_write_image(img, p.URL.path))
            snip_log("saved %s (%ldx%ld)", p.URL.path.UTF8String, (long)(sel.right - sel.left),
                     (long)(sel.bottom - sel.top));
        else
            snip_log("save failed: %s", p.URL.path.UTF8String);
    }
    CGImageRelease(img);
}

- (void)pinImage
{
    CGImageRef img = [self newRenderedImage];
    if (!img)
        return;
    RECT sel = _sel;
    ov_cancel();
    pin_create(img, sel.left, sel.top + 24);
    CGImageRelease(img);
}

/* The long screenshot samples the screen, so the overlay must be gone before it starts;
 * the work is queued because this view is torn down by ov_cancel. */
- (void)beginLong
{
    if (!_hasSel)
        return;
    RECT rc = _sel;
    dispatch_async(dispatch_get_main_queue(), ^{
      ov_cancel();
      if (!long_begin(rc))
          snip_log("long screenshot could not start");
    });
}

- (void)copySelection
{
    if (!_hasSel)
        return;
    if (!out_copy_annotated(&_shot, _sel, _anno))
        snip_log("copy failed");
    ov_cancel();
}

- (void)clearSelection
{
    if (_anno) {
        anno_list_free(_anno);
        _anno = anno_list_new();
    }
    anno_hist_free(&_hist);
    anno_hist_init(&_hist, _anno);
    _num = 1;
    _hasSel = false;
    _dragging = false;
    _dragKind = DRAG_NONE;
    _drawIdx = -1;
    _tb.palette = false;
    _tb.tool = T_NONE;
    if (g_selView == self)
        g_selView = nil;
    [self setNeedsDisplay:YES];
}

/* Debug only (SNIPLITE_OVERLAY_DEMO): a selection and a few annotations, so the edit
 * phase and the toolbar can be looked at without a mouse. */
- (void)demoSelection
{
    LONG w = (_rc.right - _rc.left) / 2, h = (_rc.bottom - _rc.top) / 2;
    _sel = (RECT){_rc.left + w / 2, _rc.top + h / 2, _rc.left + w / 2 + w, _rc.top + h / 2 + h};
    _hasSel = true;
    g_selView = self;
    CGPoint p1 = CGPointMake(w * 0.2, h * 0.2), p2 = CGPointMake(w * 0.75, h * 0.6);
    int i = anno_begin(_anno, T_RECT, 0xE53935, 1, p1);
    anno_drag(_anno, i, p2);
    i = anno_begin(_anno, T_ARROW, 0x1E88E5, 2, CGPointMake(w * 0.15, h * 0.8));
    anno_drag(_anno, i, CGPointMake(w * 0.7, h * 0.35));
    anno_add_number(_anno, 0x43A047, 1, CGPointMake(w * 0.55, h * 0.75), 1);
    anno_add_text(_anno, 0x000000, 1, CGPointMake(w * 0.12, h * 0.9), "sniplite demo");
    [self pushHistory];
    _tb.palette = getenv("SNIPLITE_OVERLAY_DEMO") && atoi(getenv("SNIPLITE_OVERLAY_DEMO")) >= 2;
    if (_tb.palette)
        _tb.hover = T_RECT; /* so the screenshot shows a tooltip too */
    [self setNeedsDisplay:YES];
}

#ifdef SNIPLITE_TEST
- (CGRect)testButton:(int)id
{
    [self layout_toolbar];
    for (int i = 0; i < _tb.nitem; i++)
        if (_tb.item[i].id == id) {
            RECT r = _tb.item[i].rc;
            return CGRectMake((r.left + r.right) / 2.0, (r.top + r.bottom) / 2.0, 1, 1);
        }
    return CGRectZero;
}

- (CGRect)testHandle:(int)index
{
    CGRect h[8];
    [self handle_rects:h];
    if (index < 1 || index > 8)
        return CGRectZero;
    CGRect r = h[index - 1];
    return CGRectMake(CGRectGetMidX(r), CGRectGetMidY(r), 1, 1);
}

- (void)testType:(NSString *)text
{
    if (!_field)
        return;
    _field.stringValue = text;
    [self commitField];
}

- (int)testTool { return _tb.tool; }
- (bool)testPaletteShown { return _tb.palette; }
- (CGRect)testPaletteCell:(int)index
{
    [self layout_toolbar];
    if (index >= 0 && index < _tb.ncolor) {
        RECT r = _tb.color_rc[index];
        return CGRectMake((r.left + r.right) / 2.0, (r.top + r.bottom) / 2.0, 1, 1);
    }
    int i = index - 100;
    if (i >= 0 && i < _tb.nsize) {
        RECT r = _tb.size_rc[i];
        return CGRectMake((r.left + r.right) / 2.0, (r.top + r.bottom) / 2.0, 1, 1);
    }
    return CGRectZero;
}
- (int)testAnnoCount { return _anno ? _anno->n : 0; }
- (RECT)testSel { return _sel; }
#endif

- (void)start
{
    NSPoint p = [NSEvent mouseLocation];
    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    _mouse = CGPointMake(p.x - _rc.left, max_top - p.y - _rc.top);
    _cursor = (POINT){(LONG)floor(p.x), (LONG)floor(max_top - p.y)};
    _inside = NSPointInRect(p, NSMakeRect(_rc.left, max_top - _rc.bottom, _rc.right - _rc.left, _rc.bottom - _rc.top));
    if (_inside) {
        g_activeView = self;
        [self refresh_cands];
    }
    [self setNeedsDisplay:YES];
}

@end

/* A new selection on another display drops what the other one was showing. */
static void clear_other_selections(NSView *keep)
{
    for (NSWindow *w in g_windows) {
        NSView *v = w.contentView;
        if (v != keep && [v isKindOfClass:[SnipOverlayView class]])
            [(SnipOverlayView *)v clearSelection];
    }
}

/* ---- showing and closing ------------------------------------------------------------------ */

static void close_overlay(void)
{
    if (!g_active && !g_windows)
        return;
    NSArray *wins = g_windows;
    g_windows = nil;
    g_active = false;
    g_activeView = nil;
    g_selView = nil;
    for (NSWindow *w in wins) {
        [w orderOut:nil];
        [(SnipOverlayView *)w.contentView teardown];
    }
    cap_free(&g_shot);
    /* The windows are released one run loop turn later: the view may be inside one of its
     * own event handlers right now (Return, Esc, a toolbar button), and releasing it there
     * would free the object whose method is still on the stack. */
    dispatch_async(dispatch_get_main_queue(), ^{
      (void)wins;
    });
    snip_log("overlay closed");
    /* give the focus back to the application the user was in */
    if (g_prev && g_prev.processIdentifier != getpid() && g_prev.isTerminated == NO) {
        [g_prev activateWithOptions:0];
        g_prev = nil;
    }
}

void ov_cancel(void)
{
    if (!g_active)
        return;
    close_overlay();
}

bool ov_active(void) { return g_active; }

/* Measured on macOS 27: -[NSApplication activate] alone leaves an LSUIElement app with
 * isActive == 0 and no key window, so the overlay would get no Esc or Return; the older
 * call does activate it. */
static void activate_app(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
}

static void relaunch_app(void)
{
    NSString *path = [[NSBundle mainBundle] bundlePath];
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        snip_log("relaunch: not running from an app bundle");
        return;
    }
    NSString *quoted = [path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *cmd = [NSString stringWithFormat:@"sleep 1.2; /usr/bin/open -n '%@'", quoted];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/sh";
    t.arguments = @[ @"-c", cmd ];
    @try {
        [t launch];
        snip_log("relaunch: %s", cmd.UTF8String);
    } @catch (NSException *e) {
        snip_log("relaunch failed: %s", e.reason.UTF8String);
    }
}

static void show_permission_alert(void)
{
    NSAlert *a = [NSAlert new];
    a.messageText = tr(@"sniplite needs the Screen Recording permission", @"sniplite 需要「屏幕录制」权限");
    a.informativeText =
        tr(@"Allow sniplite in System Settings → Privacy & Security → Screen Recording, then quit and start it again.",
           @"请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 sniplite，然后退出并重新打开 sniplite。");
    [a addButtonWithTitle:tr(@"Open System Settings", @"打开系统设置")];
    [a addButtonWithTitle:tr(@"Restart sniplite", @"重新启动 sniplite")];
    [a addButtonWithTitle:tr(@"Later", @"稍后")];
    NSModalResponse r = [a runModal];
    if (r == NSAlertFirstButtonReturn)
        [[NSWorkspace sharedWorkspace]
            openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    else if (r == NSAlertSecondButtonReturn) {
        /* macOS only applies a new screen-recording grant on launch: restart for the user
         * instead of making them find the app and quit it by hand */
        relaunch_app();
        [NSApp terminate:nil];
    }
}

static void show_capture_error(void)
{
    NSAlert *a = [NSAlert new];
    a.messageText = tr(@"sniplite could not take the screenshot", @"截图失败");
    a.informativeText = [NSString stringWithFormat:@"%s", cap_last_error()];
    [a addButtonWithTitle:tr(@"OK", @"好")];
    [a runModal];
}

static void ensure_focus(int attempt)
{
    if (!g_active)
        return;
    if (NSApp.isActive && [NSApp keyWindow] && g_activeView && g_activeView.window.isKeyWindow)
        return;
    activate_app();
    if (g_activeView) {
        [(SnipOverlayView *)g_activeView becomeKey];
        [g_activeView.window makeKeyAndOrderFront:nil];
    }
    if (attempt < 10)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
          ensure_focus(attempt + 1);
        });
}

static void show_overlay(void)
{
    g_windows = [NSMutableArray array];
    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    for (int i = 0; i < g_shot.ntile; i++) {
        RECT rc = g_shot.tile[i].rc;
        NSRect frame = NSMakeRect(rc.left, max_top - rc.bottom, rc.right - rc.left, rc.bottom - rc.top);
        SnipOverlayWindow *win = [[SnipOverlayWindow alloc] initWithContentRect:frame
                                                                      styleMask:NSWindowStyleMaskBorderless
                                                                        backing:NSBackingStoreBuffered
                                                                          defer:NO];
        win.opaque = NO;
        win.backgroundColor = [NSColor clearColor];
        win.hasShadow = NO;
        win.level = (NSWindowLevel)CGShieldingWindowLevel();
        win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
        win.acceptsMouseMovedEvents = YES;
        win.releasedWhenClosed = NO;
        SnipOverlayView *view = [[SnipOverlayView alloc] initWithShot:&g_shot rect:rc];
        win.contentView = view;
        [win orderFrontRegardless];
        [g_windows addObject:win];
        [view start];
    }
    /* The first activation request can be dropped (the system was busy, the key window
     * had not moved yet). Retry for about a second: without the focus, Enter and Esc do
     * not reach the overlay. */
    ensure_focus(0);
    if (g_activeView && getenv("SNIPLITE_OVERLAY_DEMO"))
        [(SnipOverlayView *)g_activeView demoSelection];
    /* macOS may finish moving the focus a moment after the window is ordered front; ask
     * once more so Return and Esc cannot be lost to the previous key window. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (g_active && g_activeView)
          [(SnipOverlayView *)g_activeView becomeKey];
    });
    snip_log("overlay up in %.1f ms (capture %.1f ms), %d displays, app active %d, key window %d, %lu windows",
             (CFAbsoluteTimeGetCurrent() - g_t0) * 1000.0, g_shot.ms, g_shot.ntile, (int)NSApp.isActive,
             (int)([NSApp keyWindow] != nil), (unsigned long)NSApp.windows.count);
}

bool ov_begin(void)
{
    if (g_active)
        return false;
    if (!cap_permission()) {
        cap_request_permission();
        g_active = true; /* so a second hotkey does not open a second alert */
        show_permission_alert();
        g_active = false;
        return false;
    }
    g_active = true;
    g_t0 = CFAbsoluteTimeGetCurrent();
    g_prev = [[NSWorkspace sharedWorkspace] frontmostApplication];
    unsigned gen = ++g_gen;
    cap_take(^(SnipShot *shot) {
      if (gen != g_gen || !g_active) {
          if (shot)
              cap_free(shot);
          return;
      }
      if (!shot) {
          g_active = false;
          show_capture_error();
          return;
      }
      g_shot = *shot;
      show_overlay();
    });
    return true;
}

/* ---- test hooks ------------------------------------------------------------------------
 * Compiled only into the UI test (-DSNIPLITE_TEST): they build the overlay from a synthetic
 * frame and drive the very same handlers the mouse and the keyboard call, so the selection,
 * toolbar, annotation and copy paths can be tested without a person. */
#ifdef SNIPLITE_TEST
bool ov_test_begin(const SnipShot *shot)
{
    if (g_active || !shot)
        return false;
    g_active = true;
    g_t0 = CFAbsoluteTimeGetCurrent();
    /* a deep copy: the overlay frees its frames on close, and the caller's shot must
     * survive that (cap_take hands ownership over; this hook must not) */
    g_shot = *shot;
    g_shot.tile = calloc((size_t)MAX(1, shot->ntile), sizeof(SnipTile));
    for (int i = 0; i < shot->ntile; i++) {
        g_shot.tile[i] = shot->tile[i];
        size_t bytes = (size_t)shot->tile[i].w * (size_t)shot->tile[i].h * 4;
        g_shot.tile[i].px = malloc(bytes);
        if (g_shot.tile[i].px)
            memcpy(g_shot.tile[i].px, shot->tile[i].px, bytes);
    }
    show_overlay();
    return true;
}

void ov_test_mouse(int type, double x, double y)
{
    if (!g_windows.count)
        return;
    NSWindow *w = g_windows[0];
    SnipOverlayView *v = w.contentView;
    NSPoint win = [v convertPoint:NSMakePoint(x, y) toView:nil];
    NSEventType t = type == 0 ? NSEventTypeMouseMoved
                    : type == 1 ? NSEventTypeLeftMouseDown
                    : type == 2 ? NSEventTypeLeftMouseDragged
                                : NSEventTypeLeftMouseUp;
    NSEvent *e = [NSEvent mouseEventWithType:t
                                    location:win
                               modifierFlags:0
                                   timestamp:0
                                windowNumber:w.windowNumber
                                     context:nil
                                 eventNumber:0
                                  clickCount:1
                                    pressure:1];
    switch (t) {
    case NSEventTypeMouseMoved: [v mouseMoved:e]; break;
    case NSEventTypeLeftMouseDown: [v mouseDown:e]; break;
    case NSEventTypeLeftMouseDragged: [v mouseDragged:e]; break;
    default: [v mouseUp:e]; break;
    }
}

void ov_test_key(unsigned short code, unsigned long flags)
{
    if (!g_windows.count)
        return;
    NSWindow *w = g_windows[0];
    SnipOverlayView *v = w.contentView;
    NSString *chars = code == 36 ? @"\r" : code == 53 ? @"\e" : @"";
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSZeroPoint
                             modifierFlags:flags
                                 timestamp:0
                              windowNumber:w.windowNumber
                                   context:nil
                                characters:chars
               charactersIgnoringModifiers:chars
                                  isARepeat:NO
                                    keyCode:code];
    [v keyDown:e];
}

int ov_test_anno_count(void)
{
    if (!g_windows.count)
        return -1;
    return [((NSWindow *)g_windows[0]).contentView testAnnoCount];
}

int ov_test_tool(void)
{
    if (!g_windows.count)
        return -1;
    return [((NSWindow *)g_windows[0]).contentView testTool];
}

RECT ov_test_sel(void)
{
    RECT r = {0, 0, 0, 0};
    if (g_windows.count) {
        r = [((NSWindow *)g_windows[0]).contentView testSel];
    }
    return r;
}

bool ov_test_click_button(int id)
{
    if (!g_windows.count)
        return false;
    SnipOverlayView *v = ((NSWindow *)g_windows[0]).contentView;
    CGRect c = [v testButton:id];
    if (c.size.width <= 0)
        return false;
    ov_test_mouse(1, c.origin.x, c.origin.y);
    ov_test_mouse(3, c.origin.x, c.origin.y);
    return true;
}

bool ov_test_handle_point(int index, double *x, double *y)
{
    if (!g_windows.count)
        return false;
    CGRect c = [((NSWindow *)g_windows[0]).contentView testHandle:index];
    if (c.size.width <= 0)
        return false;
    *x = c.origin.x;
    *y = c.origin.y;
    return true;
}

bool ov_test_click_palette(int index)
{
    if (!g_windows.count)
        return false;
    SnipOverlayView *v = ((NSWindow *)g_windows[0]).contentView;
    if (![v testPaletteShown] && !ov_test_click_button(B_COLOR))
        return false; /* open the palette with the colour swatch */
    /* the palette lays out on the next layout pass */
    CGRect c = [v testPaletteCell:index];
    if (c.size.width <= 0)
        return false;
    ov_test_mouse(1, c.origin.x, c.origin.y);
    ov_test_mouse(3, c.origin.x, c.origin.y);
    return true;
}

bool ov_test_type(const char *utf8)
{
    if (!g_windows.count || !utf8)
        return false;
    NSString *s = [NSString stringWithUTF8String:utf8];
    [((NSWindow *)g_windows[0]).contentView testType:s];
    return true;
}
#endif
