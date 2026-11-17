/* draw_cg.h: what the macOS overlay needs to paint: anti-aliased primitives in the
 * annotation coordinate space, the icon programs of the toolbar, and the dimension of
 * text. The Windows build draws this with a hand-written SSE rasterizer (src/draw.S);
 * here the same shapes are Core Graphics paths, which are GPU-composited when they land
 * in a window and go through the same code when they land in the output bitmap.
 *
 * Colours are 0xRRGGBB with an alpha 0..255, as in draw.h, so the shared palette and the
 * icon data stay the same values. Coordinates are points in a y-down space. */
#pragma once

#include <CoreGraphics/CoreGraphics.h>

#include <stdbool.h>
#include <stdint.h>

#include "icons.h"

/* Filled rect. */
void dc_fill(CGContextRef cg, CGRect r, uint32_t rgb, int alpha);
/* Stroke a rect with width w inside r. */
void dc_stroke(CGContextRef cg, CGRect r, CGFloat w, uint32_t rgb, int alpha);
void dc_dash_stroke(CGContextRef cg, CGRect r, CGFloat w, uint32_t rgb, int alpha, CGFloat dash);
void dc_line(CGContextRef cg, CGPoint a, CGPoint b, CGFloat w, uint32_t rgb, int alpha);
void dc_polyline(CGContextRef cg, const CGPoint *p, int n, CGFloat w, uint32_t rgb, int alpha);
void dc_ellipse(CGContextRef cg, CGRect r, CGFloat w, uint32_t rgb, int alpha);
void dc_fill_ellipse(CGContextRef cg, CGRect r, uint32_t rgb, int alpha);
void dc_fill_polygon(CGContextRef cg, const CGPoint *p, int n, uint32_t rgb, int alpha);
void dc_arrow(CGContextRef cg, CGPoint a, CGPoint b, CGFloat w, uint32_t rgb, int alpha);
void dc_dim(CGContextRef cg, CGRect r, CGFloat alpha);

/* One toolbar icon in a box; size is the box's width (and height). */
void dc_icon(CGContextRef cg, int icon, CGRect box, uint32_t rgb);

/* A single line of text, baseline at p, font size in points, y-down space. */
void dc_text(CGContextRef cg, CGPoint p, const char *utf8, double size, uint32_t rgb, int alpha);
void dc_text_bold(CGContextRef cg, CGPoint p, const char *utf8, double size, uint32_t rgb, int alpha);
double dc_text_width(CGContextRef cg, const char *utf8, double size);