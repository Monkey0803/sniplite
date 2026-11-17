/* annotate.m: the annotation list, its undo history and its renderer.
 *
 * Port of what src/ov_edit.S keeps (the list, the undo log, hit testing to come) and of
 * the drawing rules of src/ov_paint.S / src/draw.S (widths, marker alpha, mosaic block
 * size, numbered badges). The Windows build rasterizes on the CPU; here every tool is a
 * Core Graphics path, so a shape lands in a window layer and in the saved PNG through the
 * same calls. */
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "annotate.h"
#include "common.h"
#include "draw_cg.h"

const int anno_stroke[3] = {2, 4, 8};
const int anno_marker[3] = {10, 16, 26};
const int anno_block[3] = {6, 10, 16};
const int anno_font[3] = {16, 24, 36};
const int anno_number[3] = {10, 13, 18};

/* ---- list --------------------------------------------------------------------------- */

static void anno_free(SnipAnno *a)
{
    free(a->pt);
    free(a->text);
}

AnnoList *anno_list_new(void)
{
    return calloc(1, sizeof(AnnoList));
}

void anno_list_free(AnnoList *l)
{
    if (!l)
        return;
    for (int i = 0; i < l->n; i++)
        anno_free(&l->a[i]);
    free(l->a);
    free(l);
}

int anno_count(const AnnoList *l) { return l ? l->n : 0; }

const SnipAnno *anno_at(const AnnoList *l, int i)
{
    return l && i >= 0 && i < l->n ? &l->a[i] : NULL;
}

static SnipAnno *anno_new(AnnoList *l)
{
    if (l->n == l->cap) {
        int cap = l->cap ? l->cap * 2 : 16;
        SnipAnno *a = realloc(l->a, (size_t)cap * sizeof *a);
        if (!a)
            return NULL;
        l->a = a;
        l->cap = cap;
    }
    SnipAnno *a = &l->a[l->n++];
    memset(a, 0, sizeof *a);
    return a;
}

static bool anno_push_point(SnipAnno *a, CGPoint p)
{
    if (a->npt == a->cap) {
        int cap = a->cap ? a->cap * 2 : 8;
        CGPoint *q = realloc(a->pt, (size_t)cap * sizeof *q);
        if (!q)
            return false;
        a->pt = q;
        a->cap = cap;
    }
    a->pt[a->npt++] = p;
    return true;
}

int anno_begin(AnnoList *l, int tool, uint32_t color, int size, CGPoint p)
{
    SnipAnno *a = anno_new(l);
    if (!a)
        return -1;
    a->tool = tool;
    a->color = color;
    a->size = size < 0 ? 0 : size > 2 ? 2 : size;
    anno_push_point(a, p);
    if (tool != T_PEN)
        anno_push_point(a, p); /* the shape's second corner */
    return l->n - 1;
}

void anno_drag(AnnoList *l, int index, CGPoint p)
{
    if (!l || index < 0 || index >= l->n)
        return;
    SnipAnno *a = &l->a[index];
    if (a->tool == T_PEN) {
        if (a->npt) {
            CGPoint q = a->pt[a->npt - 1];
            double dx = p.x - q.x, dy = p.y - q.y;
            if (dx * dx + dy * dy < 2.25) /* don't store a point the screen can't show */
                return;
        }
        anno_push_point(a, p);
        return;
    }
    if (a->npt < 2)
        anno_push_point(a, p);
    else
        a->pt[1] = p;
}

void anno_end(AnnoList *l, int index)
{
    (void)l;
    (void)index;
}

int anno_add_text(AnnoList *l, uint32_t color, int size, CGPoint p, const char *text)
{
    SnipAnno *a = anno_new(l);
    if (!a)
        return -1;
    a->tool = T_TEXT;
    a->color = color;
    a->size = size < 0 ? 0 : size > 2 ? 2 : size;
    anno_push_point(a, p);
    a->text = text ? strdup(text) : strdup("");
    return l->n - 1;
}

int anno_add_number(AnnoList *l, uint32_t color, int size, CGPoint p, int num)
{
    SnipAnno *a = anno_new(l);
    if (!a)
        return -1;
    a->tool = T_NUMBER;
    a->color = color;
    a->size = size < 0 ? 0 : size > 2 ? 2 : size;
    anno_push_point(a, p);
    a->num = num;
    return l->n - 1;
}

AnnoList *anno_list_clone(const AnnoList *src)
{
    AnnoList *l = anno_list_new();
    if (!l)
        return NULL;
    if (!src)
        return l;
    for (int i = 0; i < src->n; i++) {
        SnipAnno *a = anno_new(l);
        if (!a)
            break;
        *a = src->a[i];
        a->pt = NULL;
        a->cap = 0;
        a->npt = 0;
        a->text = NULL;
        for (int k = 0; k < src->a[i].npt; k++)
            anno_push_point(a, src->a[i].pt[k]);
        if (src->a[i].text)
            a->text = strdup(src->a[i].text);
    }
    return l;
}

/* ---- history ------------------------------------------------------------------------- */

void anno_hist_init(AnnoHist *h, const AnnoList *l)
{
    memset(h, 0, sizeof *h);
    h->snap[0] = anno_list_clone(l);
    h->n = 1;
    h->at = 0;
}

void anno_hist_push(AnnoHist *h, const AnnoList *l)
{
    /* drop the redo tail */
    for (int i = h->at + 1; i < h->n; i++)
        anno_list_free(h->snap[i]);
    h->n = h->at + 1;
    if (h->n == (int)(sizeof h->snap / sizeof h->snap[0])) {
        anno_list_free(h->snap[0]);
        memmove(&h->snap[0], &h->snap[1], (size_t)(h->n - 1) * sizeof h->snap[0]);
        h->n--;
        h->at--;
    }
    h->snap[h->n++] = anno_list_clone(l);
    h->at = h->n - 1;
}

void anno_hist_free(AnnoHist *h)
{
    for (int i = 0; i < h->n; i++)
        anno_list_free(h->snap[i]);
    memset(h, 0, sizeof *h);
}

bool anno_hist_can_undo(const AnnoHist *h) { return h->at > 0; }
bool anno_hist_can_redo(const AnnoHist *h) { return h->at + 1 < h->n; }

const AnnoList *anno_hist_undo(AnnoHist *h)
{
    if (!anno_hist_can_undo(h))
        return h->n ? h->snap[h->at] : NULL;
    return h->snap[--h->at];
}

const AnnoList *anno_hist_redo(AnnoHist *h)
{
    if (!anno_hist_can_redo(h))
        return h->n ? h->snap[h->at] : NULL;
    return h->snap[++h->at];
}

/* ---- mosaic sampling ------------------------------------------------------------------ */

static const SnipTile *tile_of(const SnipShot *shot, long x, long y)
{
    for (int i = 0; i < shot->ntile; i++)
        if (rect_has(&shot->tile[i].rc, (int)x, (int)y))
            return &shot->tile[i];
    return NULL;
}

/* Average of a selection-local block, sampled from the frozen frame. */
static uint32_t mosaic_block(const SnipShot *shot, RECT sel, CGRect block)
{
    double gx0 = sel.left + block.origin.x, gy0 = sel.top + block.origin.y;
    double gx1 = gx0 + block.size.width, gy1 = gy0 + block.size.height;
    long ax = (long)floor(gx0), ay = (long)floor(gy0);
    long bx = (long)ceil(gx1), by = (long)ceil(gy1);
    if (bx <= ax)
        bx = ax + 1;
    if (by <= ay)
        by = ay + 1;
    long stepx = (bx - ax) / 16 + 1, stepy = (by - ay) / 16 + 1;
    uint64_t r = 0, g = 0, b = 0, n = 0;
    for (long y = ay; y < by; y += stepy)
        for (long x = ax; x < bx; x += stepx) {
            const SnipTile *t = tile_of(shot, x, y);
            if (!t)
                continue;
            int px = (int)lround((x - t->rc.left) * t->scale);
            int py = (int)lround((y - t->rc.top) * t->scale);
            if (px < 0 || py < 0 || px >= t->w || py >= t->h)
                continue;
            uint32_t c = t->px[(size_t)py * (size_t)t->w + (size_t)px];
            r += (c >> 16) & 0xFF;
            g += (c >> 8) & 0xFF;
            b += c & 0xFF;
            n++;
        }
    if (!n)
        return 0x808080;
    return (uint32_t)((r / n) << 16 | (g / n) << 8 | (b / n));
}

/* ---- renderer --------------------------------------------------------------------------- */

static CGRect rect_of(const SnipAnno *a)
{
    if (!a->npt)
        return CGRectZero;
    CGPoint p0 = a->pt[0], p1 = a->npt > 1 ? a->pt[1] : p0;
    return CGRectMake(fmin(p0.x, p1.x), fmin(p0.y, p1.y), fabs(p1.x - p0.x), fabs(p1.y - p0.y));
}

static const char *num_str(int n, char *buf, size_t cap)
{
    snprintf(buf, cap, "%d", n);
    return buf;
}

static void draw_one(CGContextRef cg, const SnipAnno *a, const SnipShot *shot, RECT sel)
{
    int si = a->size;
    switch (a->tool) {
    case T_RECT:
        dc_stroke(cg, rect_of(a), anno_stroke[si], a->color, 255);
        break;
    case T_ELLIPSE:
        dc_ellipse(cg, rect_of(a), anno_stroke[si], a->color, 255);
        break;
    case T_LINE:
        if (a->npt > 1)
            dc_line(cg, a->pt[0], a->pt[1], anno_stroke[si], a->color, 255);
        break;
    case T_ARROW:
        if (a->npt > 1)
            dc_arrow(cg, a->pt[0], a->pt[1], anno_stroke[si], a->color, 255);
        break;
    case T_PEN:
        if (a->npt > 1)
            dc_polyline(cg, a->pt, a->npt, anno_stroke[si], a->color, 255);
        break;
    case T_MARKER:
        if (a->npt > 1)
            dc_polyline(cg, a->pt, a->npt, anno_marker[si], a->color, 110);
        break;
    case T_MOSAIC: {
        CGRect r = rect_of(a);
        int block = anno_block[si];
        for (CGFloat y = 0; y < r.size.height; y += block)
            for (CGFloat x = 0; x < r.size.width; x += block) {
                CGRect b = CGRectMake(r.origin.x + x, r.origin.y + y, fmin(block, r.size.width - x),
                                      fmin(block, r.size.height - y));
                dc_fill(cg, b, mosaic_block(shot, sel, b), 255);
            }
        break;
    }
    case T_TEXT:
        if (a->text && *a->text) {
            double size = anno_font[si];
            dc_text(cg, CGPointMake(a->pt[0].x, a->pt[0].y + size * 0.8), a->text, size, a->color, 255);
        }
        break;
    case T_NUMBER: {
        double rad = anno_number[si];
        CGPoint c = {a->pt[0].x + rad * 0.5, a->pt[0].y + rad * 0.5};
        CGRect rr = CGRectMake(c.x - rad, c.y - rad, rad * 2, rad * 2);
        dc_fill_ellipse(cg, rr, a->color, 255);
        char buf[16];
        const char *s = num_str(a->num, buf, sizeof buf);
        double tw = dc_text_width(cg, s, rad * 1.1);
        dc_text_bold(cg, CGPointMake(c.x - tw / 2, c.y + rad * 0.42), s, rad * 1.1, 0xFFFFFF, 255);
        break;
    }
    default:
        break;
    }
}

void anno_render(CGContextRef cg, const AnnoList *l, const SnipShot *shot, RECT sel)
{
    if (!l)
        return;
    for (int i = 0; i < l->n; i++)
        draw_one(cg, &l->a[i], shot, sel);
}