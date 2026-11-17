/* draw_cg.c: the primitives. Everything the overlay paints with, in the y-down space
 * the views use, on top of Core Graphics. */
#include <CoreText/CoreText.h>

#include <math.h>
#include <string.h>

#include "draw_cg.h"

static CGColorRef make_color(uint32_t rgb, int alpha)
{
    CGFloat a = alpha < 0 ? 1.0 : (CGFloat)(alpha > 255 ? 255 : alpha) / 255.0;
    CGFloat comp[4] = {(CGFloat)((rgb >> 16) & 0xFF) / 255.0, (CGFloat)((rgb >> 8) & 0xFF) / 255.0,
                       (CGFloat)(rgb & 0xFF) / 255.0, a};
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef c = CGColorCreate(cs, comp);
    CGColorSpaceRelease(cs);
    return c; /* caller releases */
}

static void stroke_style(CGContextRef cg, CGFloat w)
{
    CGContextSetLineWidth(cg, w > 0 ? w : 1);
    CGContextSetLineCap(cg, kCGLineCapRound);
    CGContextSetLineJoin(cg, kCGLineJoinRound);
}

void dc_fill(CGContextRef cg, CGRect r, uint32_t rgb, int alpha)
{
    if (r.size.width <= 0 || r.size.height <= 0)
        return;
    CGColorRef c = make_color(rgb == 0xFFFFFF ? 0xFFFFFF : rgb, alpha);
    CGContextSetFillColorWithColor(cg, c);
    CGContextFillRect(cg, r);
    CGColorRelease(c);
}

void dc_stroke(CGContextRef cg, CGRect r, CGFloat w, uint32_t rgb, int alpha)
{
    if (r.size.width <= 0 || r.size.height <= 0)
        return;
    CGColorRef c = make_color(rgb, alpha);
    CGContextSetStrokeColorWithColor(cg, c);
    stroke_style(cg, w);
    CGContextStrokeRect(cg, CGRectInset(r, w / 2, w / 2));
    CGColorRelease(c);
}

void dc_dash_stroke(CGContextRef cg, CGRect r, CGFloat w, uint32_t rgb, int alpha, CGFloat dash)
{
    CGColorRef c = make_color(rgb, alpha);
    CGContextSetStrokeColorWithColor(cg, c);
    stroke_style(cg, w);
    CGContextSetLineDash(cg, 0, (CGFloat[]){dash, dash}, 2);
    CGContextStrokeRect(cg, CGRectInset(r, w / 2, w / 2));
    CGContextSetLineDash(cg, 0, NULL, 0);
    CGColorRelease(c);
}

void dc_line(CGContextRef cg, CGPoint a, CGPoint b, CGFloat w, uint32_t rgb, int alpha)
{
    CGColorRef c = make_color(rgb, alpha);
    CGContextSetStrokeColorWithColor(cg, c);
    stroke_style(cg, w);
    CGContextMoveToPoint(cg, a.x, a.y);
    CGContextAddLineToPoint(cg, b.x, b.y);
    CGContextStrokePath(cg);
    CGColorRelease(c);
}

void dc_polyline(CGContextRef cg, const CGPoint *p, int n, CGFloat w, uint32_t rgb, int alpha)
{
    if (n < 2)
        return;
    CGColorRef c = make_color(rgb, alpha);
    CGContextSetStrokeColorWithColor(cg, c);
    stroke_style(cg, w);
    CGContextMoveToPoint(cg, p[0].x, p[0].y);
    for (int i = 1; i < n; i++)
        CGContextAddLineToPoint(cg, p[i].x, p[i].y);
    CGContextStrokePath(cg);
    CGColorRelease(c);
}

void dc_ellipse(CGContextRef cg, CGRect r, CGFloat w, uint32_t rgb, int alpha)
{
    if (r.size.width <= 0 || r.size.height <= 0)
        return;
    CGColorRef c = make_color(rgb, alpha);
    CGContextSetStrokeColorWithColor(cg, c);
    stroke_style(cg, w);
    CGContextStrokeEllipseInRect(cg, CGRectInset(r, w / 2, w / 2));
    CGColorRelease(c);
}

void dc_fill_ellipse(CGContextRef cg, CGRect r, uint32_t rgb, int alpha)
{
    CGColorRef c = make_color(rgb, alpha);
    CGContextSetFillColorWithColor(cg, c);
    CGContextFillEllipseInRect(cg, r);
    CGColorRelease(c);
}

void dc_fill_polygon(CGContextRef cg, const CGPoint *p, int n, uint32_t rgb, int alpha)
{
    if (n < 3)
        return;
    CGColorRef c = make_color(rgb, alpha);
    CGContextSetFillColorWithColor(cg, c);
    CGContextMoveToPoint(cg, p[0].x, p[0].y);
    for (int i = 1; i < n; i++)
        CGContextAddLineToPoint(cg, p[i].x, p[i].y);
    CGContextClosePath(cg);
    CGContextFillPath(cg);
    CGColorRelease(c);
}

void dc_arrow(CGContextRef cg, CGPoint a, CGPoint b, CGFloat w, uint32_t rgb, int alpha)
{
    double dx = b.x - a.x, dy = b.y - a.y;
    double len = sqrt(dx * dx + dy * dy);
    if (len < 0.5)
        return;
    double ux = dx / len, uy = dy / len;
    double head = fmax(10.0, (double)w * 4.0);
    if (head > len)
        head = len;
    CGPoint shaft = {b.x - (CGFloat)(ux * head * 0.85), b.y - (CGFloat)(uy * head * 0.85)};
    dc_line(cg, a, shaft, w, rgb, alpha);
    CGPoint tip = {b.x, b.y};
    CGPoint left = {b.x - (CGFloat)(ux * head - uy * head * 0.45), b.y - (CGFloat)(uy * head + ux * head * 0.45)};
    CGPoint right = {b.x - (CGFloat)(ux * head + uy * head * 0.45), b.y - (CGFloat)(uy * head - ux * head * 0.45)};
    CGPoint tri[3] = {tip, left, right};
    dc_fill_polygon(cg, tri, 3, rgb, alpha);
}

void dc_dim(CGContextRef cg, CGRect r, CGFloat alpha)
{
    CGColorRef c = make_color(0x000000, (int)lround(alpha * 255));
    CGContextSetFillColorWithColor(cg, c);
    CGContextFillRect(cg, r);
    CGColorRelease(c);
}

/* ---- icons ------------------------------------------------------------------------- */

static void icon_stroke(CGContextRef cg, const DcIconOp *op, CGRect box, uint32_t rgb, CGFloat sw)
{
    CGFloat k = box.size.width / 20.0;
    CGFloat w = op->width == 1 ? sw * 1.15 : op->width == 2 ? sw * 1.1 : op->width == 3 ? box.size.width * 0.19 : sw;
    int alpha = op->alpha == 1 ? 110 : 255;
    if (op->kind == 1) {
        CGPoint pt[32];
        for (int i = 0; i < op->n && i < 32; i++)
            pt[i] = CGPointMake(box.origin.x + op->p[2 * i] * k, box.origin.y + op->p[2 * i + 1] * k);
        dc_polyline(cg, pt, op->n, w, rgb, alpha);
    } else if (op->kind == 2) {
        CGPoint pt[32];
        for (int i = 0; i < op->n && i < 32; i++)
            pt[i] = CGPointMake(box.origin.x + op->p[2 * i] * k, box.origin.y + op->p[2 * i + 1] * k);
        dc_fill_polygon(cg, pt, op->n, rgb, alpha);
    } else if (op->kind == 3) {
        CGRect r = CGRectMake(box.origin.x + (op->p[0] - op->p[2]) * k, box.origin.y + (op->p[1] - op->p[3]) * k,
                              2 * op->p[2] * k, 2 * op->p[3] * k);
        dc_ellipse(cg, r, w, rgb, alpha);
    }
}

void dc_icon(CGContextRef cg, int icon, CGRect box, uint32_t rgb)
{
    if (icon == IC_MOSAIC) {
        /* the icon's grid: four squares, so it reads as a pixelated block */
        CGFloat k = box.size.width / 20.0;
        for (int r = 0; r < 2; r++)
            for (int c = 0; c < 2; c++)
                dc_fill(cg, CGRectMake(box.origin.x + (3 + c * 7.5) * k, box.origin.y + (3 + r * 7.5) * k, 6.0 * k,
                                       6.0 * k),
                        rgb, 255);
        dc_stroke(cg, box, fmax(1.0, box.size.width * 0.06), rgb, 160);
        return;
    }
    const DcIconOp *ops = dc_icons[icon];
    if (!ops)
        return;
    CGFloat sw = fmax(1.2, box.size.width * 0.072);
    for (const DcIconOp *op = ops; op->kind != 0; op++)
        icon_stroke(cg, op, box, rgb, sw);
}

/* ---- text -------------------------------------------------------------------------- */

static CTFontRef ui_font(double size, bool bold)
{
    CTFontRef f = CTFontCreateUIFontForLanguage(bold ? kCTFontUIFontEmphasizedSystem : kCTFontUIFontSystem, size, NULL);
    return f ? f : CTFontCreateWithName(CFSTR("Helvetica"), size, NULL);
}

static CFAttributedStringRef make_line(const char *utf8, double size, uint32_t rgb, int alpha, bool bold,
                                       double *width)
{
    if (!utf8 || !*utf8) {
        if (width)
            *width = 0;
        return NULL;
    }
    CFStringRef s = CFStringCreateWithCString(NULL, utf8, kCFStringEncodingUTF8);
    if (!s)
        return NULL;
    CTFontRef font = ui_font(size, bold);
    CGColorRef color = make_color(rgb, alpha);
    CFDictionaryRef attrs = NULL;
    const void *keys[2] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void *vals[2] = {font, color};
    attrs = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef a = CFAttributedStringCreate(NULL, s, attrs);
    CFRelease(attrs);
    CGColorRelease(color);
    if (width) {
        CTLineRef line = CTLineCreateWithAttributedString(a);
        *width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CFRelease(line);
    }
    CFRelease(font);
    CFRelease(s);
    return a;
}

/* CoreText draws with y up; the overlay's space is y down, so the glyphs are flipped
 * around the baseline. */
static void draw_attributed(CGContextRef cg, CGPoint p, CFAttributedStringRef a)
{
    CTLineRef line = CTLineCreateWithAttributedString(a);
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, p.x, p.y);
    CGContextScaleCTM(cg, 1, -1);
    CGContextSetTextMatrix(cg, CGAffineTransformIdentity);
    CTLineDraw(line, cg);
    CGContextRestoreGState(cg);
    CFRelease(line);
}

void dc_text(CGContextRef cg, CGPoint p, const char *utf8, double size, uint32_t rgb, int alpha)
{
    CFAttributedStringRef a = make_line(utf8, size, rgb, alpha, false, NULL);
    if (a) {
        draw_attributed(cg, p, a);
        CFRelease(a);
    }
}

void dc_text_bold(CGContextRef cg, CGPoint p, const char *utf8, double size, uint32_t rgb, int alpha)
{
    CFAttributedStringRef a = make_line(utf8, size, rgb, alpha, true, NULL);
    if (a) {
        draw_attributed(cg, p, a);
        CFRelease(a);
    }
}

double dc_text_width(CGContextRef cg, const char *utf8, double size)
{
    double w = 0;
    CFAttributedStringRef a = make_line(utf8, size, 0, 255, false, &w);
    if (a)
        CFRelease(a);
    (void)cg;
    return w;
}