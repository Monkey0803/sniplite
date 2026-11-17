/* icons.h: the toolbar icons, translated from the Windows icon programs in
 * src/draw_icons.inc (kind 1 polyline, 2 convex polygon, 3 ellipse; coordinates in a
 * 0..20 grid). The data in icons_data.c is generated from that file by
 * mac/tools/gen_icons.py; the drawing is dc_icon in draw_cg.c. */
#pragma once

#include <stddef.h>
#include <stdint.h>

enum {
    IC_RECT, IC_ELLIPSE, IC_LINE, IC_ARROW, IC_PEN, IC_MARKER, IC_MOSAIC, IC_TEXT, IC_NUMBER,
    IC_UNDO, IC_REDO, IC_PIN, IC_SAVE, IC_CLOSE, IC_OK, IC_OCR, IC_OCRCOPY, IC_LONG,
    IC_COUNT
};

/* One op of an icon program: kind 1 polyline of n points, 2 convex polygon, 3 ellipse
 * (center p[0],p[1], radii p[2],p[3]); width 0..3 selects the stroke width, alpha 0 is
 * opaque and 1 is 110/255. */
typedef struct {
    uint8_t kind, n, width, alpha;
    float p[28];
} DcIconOp;

/* NULL for the icons drawn in code (the mosaic grid); see dc_icon. */
extern const DcIconOp *const dc_icons[IC_COUNT];
