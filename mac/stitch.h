/* stitch.h: the long screenshot's stitching, ported from src/scroll.c.
 *
 * Frames of the selected region arrive one at a time; the stitcher finds where the new
 * frame sits in the canvas it has built so far and appends the rows below it. It is the
 * same algorithm as the Windows build: per-row hashes over several vertical strips, a
 * vote over candidate offsets, a lost frame when the vote is not clear, and a guard for
 * rows at the bottom that did not move (toolbars, status bars). See the comment at the
 * top of src/scroll.c for why it works.
 *
 * No windows, no timers: the caller feeds it (the UI is in longscreen.m).
 */
#ifndef SNIPLITE_MAC_STITCH_H
#define SNIPLITE_MAC_STITCH_H

#include <stdbool.h>
#include <stdint.h>

#define STITCH_MAX_ROWS 32768

typedef struct {
    int w, h;               /* the frame size in pixels */
    int max_rows, max_pixels;
    int x0, seg;            /* the strips: they skip the margins (a scroll bar moves) */
    int rows;               /* canvas rows so far */
    uint32_t *canvas;       /* canvas rows, w pixels each */
    int cap;                /* rows the canvas buffer can hold */
    uint32_t *chash;        /* STITCH_STRIPS hashes per canvas row */
    uint32_t *fhash, *phash;/* per row of the frame, and of the frame before */
    int pos;                /* the canvas row at the top of the last frame that fit */
    uint32_t *last;         /* the last frame, for the footer stitch_finish appends */
    bool first, lost, full;
    void *priv;             /* the hash table and the vote bins */
} Stitch;

bool stitch_init(Stitch *s, int w, int h);
void stitch_free(Stitch *s);

/* Feed one frame of w * h pixels (BGRX, stride w). Returns the rows the canvas grew by
 * (0 when the frame did not move or could not be placed); s->lost says the latter. */
int stitch_feed(Stitch *s, const uint32_t *px);

/* The end: the rows of the last frame that were held back (a footer that stayed). */
void stitch_finish(Stitch *s);

int stitch_rows(const Stitch *s);
const uint32_t *stitch_canvas(const Stitch *s);

#endif