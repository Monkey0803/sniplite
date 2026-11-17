/* pin.m: the pinned images.
 *
 * The Windows pins are layered windows repainted with StretchDIBits (src/pin.c); here each
 * pin is a borderless NSPanel whose view draws a CGImage scaled to the panel, at a floating
 * window level so it stays above normal windows. Zoom keeps the point under the cursor in
 * place, the same gesture the Windows version has on the wheel; Cmd+wheel fades the pin.
 *
 * The menu (copy, save, reset, keep on top, close, close all) is the same set as the
 * Windows pin menu (PM_* texts). */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <math.h>
#include <stdlib.h>

#include "common.h"
#include "lang.h"
#include "output.h"
#include "pin.h"
#include "plat.h"

static NSMutableArray *g_pins;
static bool g_hidden;
static bool g_top = true; /* matches Config.pin_top */

static NSString *wstr(const WCHAR *s)
{
    char *u = snip_wstr_to_utf8(s);
    NSString *r = u ? [NSString stringWithUTF8String:u] : @"";
    free(u);
    return r;
}

/* ---- drawing ------------------------------------------------------------------------- */

@interface PinView : NSView
- (instancetype)initWithImage:(CGImageRef)img;
@end

@implementation PinView

{
    CGImageRef _img;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithImage:(CGImageRef)img
{
    CGFloat w = (CGFloat)CGImageGetWidth(img), h = (CGFloat)CGImageGetHeight(img);
    self = [super initWithFrame:NSMakeRect(0, 0, w, h)];
    if (!self)
        return nil;
    _img = CGImageRetain(img);
    return self;
}

- (void)dealloc
{
    if (_img)
        CGImageRelease(_img);
}

- (void)drawRect:(NSRect)r
{
    (void)r;
    CGContextRef cg = [NSGraphicsContext currentContext].CGContext;
    if (!cg || !_img)
        return;
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, 0, CGRectGetMaxY(self.bounds));
    CGContextScaleCTM(cg, 1, -1);
    CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
    CGContextDrawImage(cg, CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height), _img);
    CGContextRestoreGState(cg);
}

@end

/* ---- the pin panel ------------------------------------------------------------------- */

@interface PinWindow : NSPanel <NSWindowDelegate> {
    CGImageRef _img;
    CGFloat _zoom, _baseScale;
    BOOL _dragging, _moved;
    NSPoint _grab;
    NSPoint _origin;
}
- (instancetype)initWithImage:(CGImageRef)img at:(NSPoint)origin;
- (void)zoomBy:(CGFloat)factor at:(NSPoint)screenPoint;
- (void)resetZoom;
- (void)copyImage;
- (void)saveImage;
- (void)toggleTop;
- (void)closePin;
- (void)closeAll;
@end

@implementation PinWindow

- (instancetype)initWithImage:(CGImageRef)img at:(NSPoint)origin
{
    CGFloat scale = 1;
    NSScreen *s = [NSScreen mainScreen];
    for (NSScreen *sc in [NSScreen screens])
        if (NSPointInRect(origin, sc.frame)) {
            s = sc;
            break;
        }
    scale = s.backingScaleFactor > 0 ? s.backingScaleFactor : 1;
    CGFloat w = (CGFloat)CGImageGetWidth(img) / scale, h = (CGFloat)CGImageGetHeight(img) / scale;
    self = [super initWithContentRect:NSMakeRect(origin.x, origin.y, w, h)
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self)
        return nil;
    _img = CGImageRetain(img);
    _zoom = 1;
    _baseScale = scale;
    self.opaque = NO;
    self.backgroundColor = [NSColor clearColor];
    self.hasShadow = YES;
    self.level = g_top ? NSStatusWindowLevel : NSFloatingWindowLevel;
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.releasedWhenClosed = NO;
    self.delegate = self;
    self.contentView = [[PinView alloc] initWithImage:img];
    self.contentView.wantsLayer = YES;
    [self orderFrontRegardless];
    return self;
}

- (BOOL)canBecomeKeyWindow { return YES; }

- (void)dealloc
{
    if (_img)
        CGImageRelease(_img);
}

/* The image's point size at zoom 1, from its pixels and the display scale. */
- (NSSize)naturalSize
{
    return NSMakeSize((CGFloat)CGImageGetWidth(_img) / _baseScale, (CGFloat)CGImageGetHeight(_img) / _baseScale);
}

- (void)setZoom:(CGFloat)z
{
    _zoom = fmin(8, fmax(0.25, z));
    NSSize n = [self naturalSize];
    NSRect f = self.frame;
    /* keep the top-left corner, so a zoom does not walk off the screen */
    f.origin.y = CGRectGetMaxY(f) - n.height * _zoom;
    f.size = NSMakeSize(n.width * _zoom, n.height * _zoom);
    [self setFrame:f display:YES];
}

- (void)zoomBy:(CGFloat)factor at:(NSPoint)screenPoint
{
    NSSize old = self.frame.size;
    double z = _zoom * factor;
    [self setZoom:z];
    NSSize now = self.frame.size;
    if (old.width > 0 && old.height > 0) {
        double fx = (screenPoint.x - self.frame.origin.x) / now.width;
        double fy = (screenPoint.y - self.frame.origin.y) / now.height;
        NSRect f = self.frame;
        f.origin.x = screenPoint.x - fx * now.width;
        f.origin.y = screenPoint.y - fy * now.height;
        [self setFrame:f display:YES];
    }
}

- (void)resetZoom
{
    [self setZoom:1];
}

- (void)mouseDown:(NSEvent *)e
{
    _dragging = YES;
    _moved = NO;
    _grab = [NSEvent mouseLocation];
    _origin = self.frame.origin;
    [self makeKeyAndOrderFront:nil];
}

- (void)mouseDragged:(NSEvent *)e
{
    if (!_dragging)
        return;
    NSPoint p = [NSEvent mouseLocation];
    if (fabs(p.x - _grab.x) + fabs(p.y - _grab.y) > 1)
        _moved = YES;
    NSRect f = self.frame;
    f.origin = NSMakePoint(_origin.x + (p.x - _grab.x), _origin.y + (p.y - _grab.y));
    [self setFrameOrigin:f.origin];
}

- (void)mouseUp:(NSEvent *)e
{
    if (_dragging && !_moved && e.clickCount >= 2)
        [self close];
    _dragging = NO;
}

- (void)scrollWheel:(NSEvent *)e
{
    NSPoint p = [NSEvent mouseLocation];
    if (e.modifierFlags & NSEventModifierFlagCommand) {
        CGFloat a = self.alphaValue + (e.scrollingDeltaY > 0 ? 0.05 : -0.05);
        self.alphaValue = fmin(1.0, fmax(0.2, a));
        return;
    }
    CGFloat f = e.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1;
    [self zoomBy:f at:p];
}

- (void)rightMouseDown:(NSEvent *)e
{
    NSMenu *m = [[NSMenu alloc] init];
    struct {
        const WCHAR *text;
        SEL sel;
    } items[] = {
        {T(PM_COPY), @selector(copyImage)},
        {T(PM_SAVE), @selector(saveImage)},
        {T(PM_RESET), @selector(resetZoom)},
        {T(PM_TOP), @selector(toggleTop)},
        {T(PM_CLOSE), @selector(closePin)},
        {T(M_CLOSE_PINS), @selector(closeAll)},
    };
    for (size_t i = 0; i < sizeof items / sizeof items[0]; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:wstr(items[i].text) action:items[i].sel keyEquivalent:@""];
        it.target = self;
        [m addItem:it];
    }
    [NSMenu popUpContextMenu:m withEvent:e forView:self.contentView];
}

- (void)copyImage
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:_img];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setData:[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
    snip_log("pin: copied to the pasteboard");
}

- (void)saveImage
{
    BOOL wasVisible = self.isVisible;
    [self orderOut:nil]; /* the panel must not cover the save dialog */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES]; /* the panel belongs to this app */
#pragma clang diagnostic pop
    NSSavePanel *p = [NSSavePanel savePanel];
    p.allowedContentTypes = @[ UTTypePNG, UTTypeJPEG ];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    p.nameFieldStringValue = [NSString stringWithFormat:@"sniplite-pin_%@.png", [f stringFromDate:[NSDate date]]];
    if ([p runModal] == NSModalResponseOK && p.URL)
        snip_log(out_write_image(_img, p.URL.path) ? "pin: saved %s" : "pin: save failed: %s", p.URL.path.UTF8String);
    if (wasVisible && !g_hidden)
        [self orderFrontRegardless];
}

- (void)toggleTop
{
    g_top = !g_top;
    [self setLevel:g_top ? NSStatusWindowLevel : NSFloatingWindowLevel];
}

- (void)closePin { [self close]; }

- (void)closeAll { pin_close_all(); }

- (void)keyDown:(NSEvent *)e
{
    if (e.keyCode == 53) { /* Esc */
        [self close];
        return;
    }
    [super keyDown:e];
}

- (void)windowWillClose:(NSNotification *)n
{
    (void)n;
    [g_pins removeObject:self];
}

@end

/* ---- text to image -------------------------------------------------------------------- */

static CGImageRef text_image(NSString *text)
{
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName : [NSColor blackColor],
    };
    NSSize size = [text boundingRectWithSize:NSMakeSize(640, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:attrs]
                      .size;
    CGFloat w = ceil(size.width) + 28, h = ceil(size.height) + 24;
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img lockFocus];
    [[NSColor whiteColor] setFill];
    NSRectFill(NSMakeRect(0, 0, w, h));
    [[NSColor colorWithCalibratedWhite:0 alpha:0.12] setFill];
    NSFrameRect(NSMakeRect(0, 0, w, h));
    [text drawInRect:NSMakeRect(14, 12, size.width, size.height) withAttributes:attrs];
    [img unlockFocus];
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    return cg ? CGImageCreateCopy(cg) : NULL;
}

/* ---- the pins --------------------------------------------------------------------------- */

static void ensure_list(void)
{
    if (!g_pins)
        g_pins = [NSMutableArray array];
}

void pin_create(CGImageRef img, int x, int y)
{
    ensure_list();
    CGFloat max_top = 0;
    for (NSScreen *s in [NSScreen screens])
        max_top = MAX(max_top, NSMaxY(s.frame));
    /* the display the pin's top-left corner lands on decides its scale */
    CGFloat scale = 1;
    for (NSScreen *s in [NSScreen screens]) {
        NSRect tl = NSMakeRect(s.frame.origin.x, max_top - NSMaxY(s.frame), s.frame.size.width, s.frame.size.height);
        if (x >= tl.origin.x && x < NSMaxX(tl) && y >= tl.origin.y && y < NSMaxY(tl)) {
            scale = s.backingScaleFactor > 0 ? s.backingScaleFactor : 1;
            break;
        }
    }
    CGFloat h = (CGFloat)CGImageGetHeight(img) / scale;
    /* y is the desired top edge in the top-left space; the panel's origin is its bottom-left */
    NSPoint p = NSMakePoint(x, max_top - y - h);
    PinWindow *win = [[PinWindow alloc] initWithImage:img at:p];
    if (win) {
        [g_pins addObject:win];
        snip_log("pin: %d pins, frame %s visible %d occlusion %lu screen %s", (int)g_pins.count,
                 [NSStringFromRect(win.frame) UTF8String], (int)win.isVisible,
                 (unsigned long)win.occlusionState, win.screen.localizedName.UTF8String ?: "?");
    }
}

int pin_count(void)
{
    ensure_list();
    return (int)g_pins.count;
}

void pin_toggle_all(void)
{
    ensure_list();
    if (!g_pins.count)
        return;
    g_hidden = !g_hidden;
    for (PinWindow *w in g_pins) {
        if (g_hidden)
            [w orderOut:nil];
        else
            [w orderFrontRegardless];
    }
    snip_log("pins: %s", g_hidden ? "hidden" : "shown");
}

bool pin_all_hidden(void) { return g_hidden; }

void pin_close_all(void)
{
    ensure_list();
    for (PinWindow *w in [g_pins copy])
        [w close];
    [g_pins removeAllObjects];
}

void pin_set_top(bool on)
{
    g_top = on;
    pin_refresh_levels();
}

void pin_refresh_levels(void)
{
    ensure_list();
    for (PinWindow *w in g_pins)
        [w setLevel:g_top ? NSStatusWindowLevel : NSFloatingWindowLevel];
}

bool pin_from_clipboard(void)
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSData *png = [pb dataForType:NSPasteboardTypePNG];
    NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
    CGImageRef img = NULL;
    if (png.length) {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
        if (src) {
            CGImageRef c = CGImageSourceCreateImageAtIndex(src, 0, NULL);
            CFRelease(src);
            img = c; /* +1 */
        }
    }
    if (!img && tiff.length) {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)tiff, NULL);
        if (src) {
            CGImageRef c = CGImageSourceCreateImageAtIndex(src, 0, NULL);
            CFRelease(src);
            img = c;
        }
    }
    if (!img) {
        NSString *s = [pb stringForType:NSPasteboardTypeString];
        if (s.length)
            img = text_image(s);
    }
    if (!img)
        return false;
    NSPoint m = [NSEvent mouseLocation];
    int x = (int)lround(m.x), y = (int)lround([[NSScreen screens].firstObject frame].size.height - m.y);
    pin_create(img, x, y);
    CGImageRelease(img);
    return true;
}

#ifdef SNIPLITE_TEST
static PinWindow *last_pin(void)
{
    ensure_list();
    return g_pins.count ? g_pins.lastObject : nil;
}

double pin_test_zoom_last(double factor, double *width)
{
    PinWindow *w = last_pin();
    if (!w)
        return -1;
    NSRect f = w.frame;
    [w zoomBy:factor at:NSPointFromCGPoint(CGPointMake(NSMidX(f), NSMidY(f)))];
    if (width)
        *width = w.frame.size.width;
    return w.frame.size.width / (f.size.width > 0 ? f.size.width : 1);
}

double pin_test_alpha_last(void)
{
    PinWindow *w = last_pin();
    return w ? w.alphaValue : -1;
}

int pin_test_level_last(void)
{
    PinWindow *w = last_pin();
    return w ? (int)w.level : -1;
}
#endif
