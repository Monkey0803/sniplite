/* annotate.h: the annotation model of the macOS overlay, the undo history, and the
 * renderer that paints both the on-screen selection and the copied image.
 *
 * The model is the one of src/ov_edit.S: every annotation keeps its tool, colour, size
 * index and points; coordinates are the selection's own (0,0 at its top-left corner, in
 * points), so the same list paints in a view and in the output bitmap by setting the
 * context's transform. The tool ids and the palette come from the shared header
 * (src/ov_layout.inc, src/ov_base.S) so both ports draw the same values.
 *
 * Undo is a stack of whole-list snapshots, like the Windows op log but without the
 * reference counting; a screenshot has few annotations, so copying them is cheaper than
 * tracking every mutation. */
#pragma once

#include <CoreGraphics/CoreGraphics.h>

#include <stdbool.h>
#include <stdint.h>

#include "capture.h"
#include "ov_layout.inc" /* T_*, ACCENT, PH_* */

typedef struct {
    int tool;
    uint32_t color;
    int size; /* 0..2: picks from the width, marker, block and font tables */
    CGPoint *pt;
    int npt, cap;
    char *text; /* T_TEXT */
    int num;    /* T_NUMBER */
} SnipAnno;

typedef struct {
    SnipAnno *a;
    int n, cap;
} AnnoList;

AnnoList *anno_list_new(void);
AnnoList *anno_list_clone(const AnnoList *l);
void anno_list_free(AnnoList *l);
int anno_count(const AnnoList *l);
const SnipAnno *anno_at(const AnnoList *l, int i);

/* Start an annotation at p (selection-local points). Returns its index, or -1. Pen
 * strokes grow with anno_drag; the shape tools move their second point. */
int anno_begin(AnnoList *l, int tool, uint32_t color, int size, CGPoint p);
void anno_drag(AnnoList *l, int index, CGPoint p);
void anno_end(AnnoList *l, int index);
int anno_add_text(AnnoList *l, uint32_t color, int size, CGPoint p, const char *text);
int anno_add_number(AnnoList *l, uint32_t color, int size, CGPoint p, int num);

/* Undo history: snapshot 0 is the empty list; undo/redo return the list to draw. */
typedef struct {
    AnnoList *snap[64];
    int n, at;
} AnnoHist;

void anno_hist_init(AnnoHist *h, const AnnoList *l);
void anno_hist_push(AnnoHist *h, const AnnoList *l);
void anno_hist_free(AnnoHist *h);
bool anno_hist_can_undo(const AnnoHist *h);
bool anno_hist_can_redo(const AnnoHist *h);
const AnnoList *anno_hist_undo(AnnoHist *h);
const AnnoList *anno_hist_redo(AnnoHist *h);

/* Paint in selection-local points: the caller sets the transform so that this space
 * lands where the selection is (the view) or at the output scale (the bitmap). */
void anno_render(CGContextRef cg, const AnnoList *l, const SnipShot *shot, RECT sel);

/* The width tables of src/ov_base.S (kStroke, kMarker, kBlock, kFont, kNumber). */
extern const int anno_stroke[3];
extern const int anno_marker[3];
extern const int anno_block[3];
extern const int anno_font[3];
extern const int anno_number[3];