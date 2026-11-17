/* toolbar.c: the annotation toolbar of the macOS overlay.
 *
 * A rounded dark bar with the nine tools, the colour and size pickers, undo/redo and the
 * output buttons; a second bar with the palette (the eight colours of src/ov_base.S) and
 * the three sizes. The colours and the icon programs are the Windows ones; the geometry
 * is macOS's (points, 30 pt buttons).
 *
 * The bar is placed under the selection (above it when there is no room, inside it when
 * neither fits), and the palette under the bar, the same rule the Windows overlay uses
 * (place_toolbar in src/ov_paint.S). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "draw_cg.h"
#include "icons.h"
#include "lang.h"
#include "plat.h"
#include "toolbar.h"

#define BTN 30.0
#define GAP 5.0
#define PAD 7.0
#define SEP 9.0
#define RADIUS 9.0
#define ICON 21.0
#define BAR_GAP 6.0

const uint32_t tb_palette[8] = {0xE53935, 0xFB8C00, 0xFDD835, 0x43A047, 0x1E88E5, 0x8E24AA, 0x000000, 0xFFFFFF};

static int icon_of(int id)
{
    if (id >= T_RECT && id <= T_NUMBER)
        return IC_RECT + (id - T_RECT);
    switch (id) {
    case B_UNDO: return IC_UNDO;
    case B_REDO: return IC_REDO;
    case B_PIN: return IC_PIN;
    case B_SAVE: return IC_SAVE;
    case B_CLOSE: return IC_CLOSE;
    case B_OK: return IC_OK;
    case B_LONG: return IC_LONG;
    case B_OCR: return IC_OCR;
    case B_OCRCOPY: return IC_OCRCOPY;
    default: return -1;
    }
}

static const char *tip_of(int id)
{
    static char buf[256];
    const WCHAR *t = NULL;
    switch (id) {
    case T_RECT: t = T(TIP_TOOL1); break;
    case T_ELLIPSE: t = T(TIP_TOOL2); break;
    case T_LINE: t = T(TIP_TOOL3); break;
    case T_ARROW: t = T(TIP_TOOL4); break;
    case T_PEN: t = T(TIP_TOOL5); break;
    case T_MARKER: t = T(TIP_TOOL6); break;
    case T_MOSAIC: t = T(TIP_TOOL7); break;
    case T_TEXT: t = T(TIP_TOOL8); break;
    case T_NUMBER: t = T(TIP_TOOL9); break;
    case B_UNDO: t = T(TIP_UNDO); break;
    case B_REDO: t = T(TIP_REDO); break;
    case B_PIN: t = T(TIP_PIN); break;
    case B_SAVE: t = T(TIP_SAVE); break;
    case B_CLOSE: t = T(TIP_QUIT); break;
    case B_OK: t = T(TIP_COPY); break;
    case B_LONG: t = T(TIP_LONG); break;
    case B_OCR: t = T(TIP_OCR); break;
    case B_OCRCOPY: t = T(TIP_OCRCOPY); break;
    default: return "";
    }
    char *u = snip_wstr_to_utf8(t);
    if (!u)
        return "";
    snprintf(buf, sizeof buf, "%s", u);
    free(u);
    return buf;
}

static void add_item(Tb *t, int id, double *x, double y, double h, double w)
{
    if (t->nitem >= (int)(sizeof t->item / sizeof t->item[0]))
        return;
    t->item[t->nitem].id = id;
    t->item[t->nitem].rc = (RECT){(LONG)lround(*x), (LONG)lround(y), (LONG)lround(*x + w), (LONG)lround(y + h)};
    t->nitem++;
    *x += w + GAP;
}

void tb_layout(Tb *t, RECT sel, CGRect bounds)
{
    t->nitem = 0;
    t->ncolor = 0;
    t->nsize = 0;
    t->tb = (RECT){0, 0, 0, 0};
    t->pb = (RECT){0, 0, 0, 0};

    static const int kBar[] = {T_RECT, T_ELLIPSE, T_LINE, T_ARROW, T_PEN, T_MARKER, T_MOSAIC, T_TEXT, T_NUMBER,
                               -1, B_COLOR, B_SIZE, -1, B_UNDO, B_REDO, -1, B_LONG, B_PIN, B_SAVE, B_CLOSE, B_OK};
    double w = PAD;
    for (size_t i = 0; i < sizeof kBar / sizeof kBar[0]; i++)
        w += kBar[i] == -1 ? SEP : BTN + GAP;
    w += PAD - GAP;
    double h = BTN + 2 * PAD;

    double sel_h = sel.bottom - sel.top;
    double x = sel.right - w; /* right-aligned with the selection, like the Windows bar */
    double y = bounds.size.height - (sel.bottom + BAR_GAP + h); /* just under it */
    if (y < 0)
        y = sel.top - BAR_GAP - h; /* no room under: above it */
    if (x < 0)
        x = 0;
    if (x + w > bounds.size.width)
        x = bounds.size.width - w;
    if (y < 0 || y + h > bounds.size.height) {
        /* neither side: inside the selection, at its bottom */
        y = bounds.size.height - (sel.bottom - 2) - h;
        if (y < 0)
            y = 2;
        if (y < sel.top + sel_h && y + h > sel.top)
            y = fmax(2.0, sel.top + sel_h - h - 2);
    }
    t->tb = (RECT){(LONG)lround(x), (LONG)lround(y), (LONG)lround(x + w), (LONG)lround(y + h)};

    double cx = x + PAD, cy = y + PAD;
    for (size_t i = 0; i < sizeof kBar / sizeof kBar[0]; i++) {
        if (kBar[i] == -1) {
            cx += SEP;
            continue;
        }
        add_item(t, kBar[i], &cx, cy, BTN, BTN);
    }

    if (t->palette) {
        double pw = 8 * (24 + 6) - 6 + 2 * 8 + SEP + 3 * (30 + 6) - 6 + 2 * 8;
        double ph = 30 + 16;
        double px = t->tb.right - pw;
        double py = t->tb.bottom + BAR_GAP;
        if (py + ph > bounds.size.height)
            py = t->tb.top - BAR_GAP - ph;
        if (px < 0)
            px = 0;
        if (px + pw > bounds.size.width)
            px = bounds.size.width - pw;
        if (py < 0)
            py = 0;
        t->pb = (RECT){(LONG)lround(px), (LONG)lround(py), (LONG)lround(px + pw), (LONG)lround(py + ph)};
        double kx = px + 8, ky = py + 8;
        for (int i = 0; i < 8; i++) {
            t->color_rc[t->ncolor++] = (RECT){(LONG)lround(kx), (LONG)lround(ky), (LONG)lround(kx + 24),
                                              (LONG)lround(ky + 24)};
            kx += 30;
        }
        kx += SEP;
        for (int i = 0; i < 3; i++) {
            t->size_rc[t->nsize++] = (RECT){(LONG)lround(kx), (LONG)lround(ky), (LONG)lround(kx + 30),
                                            (LONG)lround(ky + 30)};
            kx += 36;
        }
    }
}

static bool in_rect(RECT r, CGPoint p) { return p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom; }

int tb_hit(const Tb *t, CGPoint p)
{
    for (int i = 0; i < t->nitem; i++)
        if (in_rect(t->item[i].rc, p))
            return t->item[i].id;
    return 0;
}

int tb_palette_hit(const Tb *t, CGPoint p)
{
    for (int i = 0; i < t->ncolor; i++)
        if (in_rect(t->color_rc[i], p))
            return i;
    for (int i = 0; i < t->nsize; i++)
        if (in_rect(t->size_rc[i], p))
            return 100 + i;
    return -1;
}

/* ---- drawing ------------------------------------------------------------------------- */

static void rounded(CGContextRef cg, RECT r, double radius, uint32_t rgb, int alpha)
{
    CGRect rect = CGRectMake(r.left, r.top, r.right - r.left, r.bottom - r.top);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comp[4] = {(CGFloat)((rgb >> 16) & 0xFF) / 255.0, (CGFloat)((rgb >> 8) & 0xFF) / 255.0,
                       (CGFloat)(rgb & 0xFF) / 255.0, (CGFloat)alpha / 255.0};
    CGColorRef c = CGColorCreate(cs, comp);
    CGContextSetFillColorWithColor(cg, c);
    CGContextAddPath(cg, path);
    CGContextFillPath(cg);
    CGColorRelease(c);
    CGColorSpaceRelease(cs);
    CGPathRelease(path);
}

static void tooltip(CGContextRef cg, const Tb *t, int id, RECT rc)
{
    const char *tip = tip_of(id);
    if (!*tip)
        return;
    double size = 11;
    double tw = dc_text_width(cg, tip, size);
    double w = tw + 16, h = size + 12;
    double x = rc.left + (rc.right - rc.left) / 2 - w / 2;
    double y = rc.top - h - 6;
    if (y < 2)
        y = rc.bottom + 6;
    if (x < 2)
        x = 2;
    RECT box = {(LONG)lround(x), (LONG)lround(y), (LONG)lround(x + w), (LONG)lround(y + h)};
    rounded(cg, box, 5, 0x000000, 235);
    dc_text(cg, CGPointMake(x + 8, y + h - 8), tip, size, 0xFFFFFF, 255);
}

void tb_draw(CGContextRef cg, const Tb *t)
{
    if (!t->tb.right)
        return;
    rounded(cg, t->tb, RADIUS, 0x1E1E1E, 242);
    rounded(cg, (RECT){t->tb.left, t->tb.top, t->tb.right, t->tb.top + 1}, 0, 0xFFFFFF, 40);

    for (int i = 0; i < t->nitem; i++) {
        int id = t->item[i].id;
        RECT rc = t->item[i].rc;
        bool active = (id >= T_RECT && id <= T_NUMBER) ? id == t->tool : false;
        bool dim = (id == B_UNDO && !t->can_undo) || (id == B_REDO && !t->can_redo);
        if (t->hover == id)
            rounded(cg, (RECT){rc.left - 2, rc.top - 2, rc.right + 2, rc.bottom + 2}, 6, 0xFFFFFF, 38);
        if (active)
            rounded(cg, (RECT){rc.left - 2, rc.top - 2, rc.right + 2, rc.bottom + 2}, 6, ACCENT, 230);

        if (id == B_COLOR || id == B_SIZE) {
            /* a swatch: the current colour, or three dots for the width */
            if (id == B_COLOR) {
                CGRect c = CGRectMake(rc.left + 7, rc.top + 7, rc.right - rc.left - 14, rc.bottom - rc.top - 14);
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGFloat comp[4] = {(CGFloat)((t->color >> 16) & 0xFF) / 255.0,
                                   (CGFloat)((t->color >> 8) & 0xFF) / 255.0, (CGFloat)(t->color & 0xFF) / 255.0, 1};
                CGColorRef col = CGColorCreate(cs, comp);
                CGColorSpaceRelease(cs);
                CGContextSetFillColorWithColor(cg, col);
                CGContextFillEllipseInRect(cg, c);
                CGColorRelease(col);
                dc_ellipse(cg, CGRectInset(c, -1.5, -1.5), 1.5, 0xFFFFFF, 200);
            } else {
                for (int k = 0; k < 3; k++) {
                    double rad = 2 + k * 2.2;
                    CGRect c = CGRectMake(rc.left + (rc.right - rc.left) / 2 - rad, rc.top + 10 + k * 5.5 - rad,
                                          2 * rad, 2 * rad);
                    dc_fill_ellipse(cg, c, t->color, 255);
                }
            }
            continue;
        }

        int icon = icon_of(id);
        if (icon >= 0) {
            CGRect box = CGRectMake(rc.left + (rc.right - rc.left - ICON) / 2,
                                    rc.top + (rc.bottom - rc.top - ICON) / 2, ICON, ICON);
            dc_icon(cg, icon, box, 0xFFFFFF);
        }
        if (dim)
            rounded(cg, rc, 6, 0x1E1E1E, 120); /* looks unavailable */
    }

    if (t->hover > 0)
        for (int i = 0; i < t->nitem; i++)
            if (t->item[i].id == t->hover) {
                tooltip(cg, t, t->hover, t->item[i].rc);
                break;
            }

    if (t->palette && t->pb.right) {
        rounded(cg, t->pb, RADIUS, 0x1E1E1E, 242);
        for (int i = 0; i < t->ncolor; i++) {
            RECT rc = t->color_rc[i];
            CGRect c = CGRectMake(rc.left + 2, rc.top + 2, rc.right - rc.left - 4, rc.bottom - rc.top - 4);
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGFloat comp[4] = {(CGFloat)((tb_palette[i] >> 16) & 0xFF) / 255.0, (CGFloat)((tb_palette[i] >> 8) & 0xFF) / 255.0,
                               (CGFloat)(tb_palette[i] & 0xFF) / 255.0, 1};
            CGColorRef col = CGColorCreate(cs, comp);
            CGColorSpaceRelease(cs);
            CGContextSetFillColorWithColor(cg, col);
            CGContextFillEllipseInRect(cg, c);
            CGColorRelease(col);
            if (tb_palette[i] == t->color)
                dc_ellipse(cg, CGRectInset(c, -2, -2), 2, ACCENT, 255);
        }
        for (int i = 0; i < t->nsize; i++) {
            RECT rc = t->size_rc[i];
            double rad = 3 + i * 3.2;
            CGRect c = CGRectMake(rc.left + (rc.right - rc.left) / 2 - rad, rc.top + (rc.bottom - rc.top) / 2 - rad,
                                  2 * rad, 2 * rad);
            dc_fill_ellipse(cg, c, t->color, 255);
            if (i == t->size)
                dc_ellipse(cg, CGRectInset(c, -4, -4), 1.5, ACCENT, 255);
        }
    }
}