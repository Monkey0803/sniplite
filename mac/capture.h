/* capture.h: one frozen frame of every display, in the pixel format the shared drawing
 * code expects (BGRX, top-down, stride == width), plus the windows on top of a point.
 *
 * Objective-C only (blocks in the interface). Coordinates are global top-left points,
 * the same space event locations are converted to; each tile carries the scale that
 * turns its points into pixels (2 on a Retina display, 1 otherwise). */
#pragma once

#import <Foundation/Foundation.h>

#include <stdbool.h>
#include <stdint.h>

#include "plat.h"

typedef struct {
    RECT rc;      /* where this tile is, global top-left points */
    float scale;  /* pixels per point of that display */
    uint32_t *px; /* BGRX, stride == w pixels, first row at rc.top */
    int w, h;     /* pixels */
} SnipTile;

typedef struct {
    RECT vs; /* virtual screen: union of the tiles, global top-left points */
    SnipTile *tile;
    int ntile;
    double ms; /* how long the capture took */
} SnipShot;

/* Screen recording permission (TCC). The first capture of a fresh install fails until
 * the user grants it in System Settings, and macOS only applies it after a relaunch. */
bool cap_permission(void);
void cap_request_permission(void);

/* Resolve the displays once at start-up so the first hotkey does not pay for it. */
void cap_prewarm(void);
/* Forget the cached displays (they changed: plugged, unplugged, rearranged). */
void cap_invalidate(void);

/* Take the frames of all displays, concurrently. Asynchronous: done() is called on the
 * main queue with a shot (free it with cap_free) or NULL when the capture failed
 * (cap_last_error() says why). */
void cap_take(void (^done)(SnipShot *shot));

void cap_free(SnipShot *shot);
const char *cap_last_error(void);

/* One frame of a region (global top-left points), at that display's scale: the long
 * screenshot's sampler. Asynchronous; done() on the main queue with a malloc'd BGRX
 * buffer (free it) and its pixel size, or NULL. */
void cap_sample_rect(RECT rc, void (^done)(uint32_t *px, int w, int h));

/* The windows under a point, front to back: the first one is the window the user sees.
 * Global top-left points; out may be NULL to only count. */
int cap_windows_at(int x, int y, RECT *out, int max);
