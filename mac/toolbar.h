/* toolbar.h: the annotation toolbar and the colour/size bar under the selection.
 *
 * Layout and hit testing only; the state (current tool, colour, size) belongs to the
 * overlay. The button ids are the ones of src/ov_layout.inc (T_* for the tools, B_* for
 * the actions), and the icon glyphs are the Windows ones (mac/icons_data.c), so the bar
 * reads the same as in the Windows build. */
#pragma once

#include <CoreGraphics/CoreGraphics.h>

#include <stdbool.h>
#include <stdint.h>

#include "common.h"
#include "ov_layout.inc"

typedef struct {
    int tool;
    uint32_t color;
    int size;
    bool palette; /* the colour/size bar is showing */

    RECT tb, pb; /* boxes in view-local points */
    struct {
        int id;
        RECT rc;
    } item[32];
    int nitem;
    RECT color_rc[8];
    int ncolor;
    RECT size_rc[3];
    int nsize;

    int hover; /* id under the mouse, 0 for none */
    bool can_undo, can_redo;
} Tb;

extern const uint32_t tb_palette[8];

void tb_layout(Tb *t, RECT sel, CGRect bounds);
int tb_hit(const Tb *t, CGPoint p); /* 0 or an id (tool, B_COLOR, B_SIZE, B_*) */
void tb_draw(CGContextRef cg, const Tb *t);
int tb_palette_hit(const Tb *t, CGPoint p); /* -1, or 0..7 colour / 100+0..2 size */