/* overlay.h: the interactive capture (Phase 2: selection only; annotations come next). */
#pragma once

#include <stdbool.h>

#include "capture.h"

/* Start a capture: frozen frames first, then one full-screen window over all displays.
 * False when a capture is already running or the permission is missing (the user gets an
 * explanation and a shortcut to System Settings). */
bool ov_begin(void);
bool ov_active(void);
void ov_cancel(void);

#ifdef SNIPLITE_TEST
/* The UI test's hooks: show the overlay over a synthetic frame and drive the same handlers
 * the mouse and the keyboard call. Compiled only with -DSNIPLITE_TEST. */
bool ov_test_begin(const SnipShot *shot);
void ov_test_mouse(int type, double x, double y); /* 0 move, 1 down, 2 drag, 3 up */
void ov_test_key(unsigned short code, unsigned long flags);
int ov_test_anno_count(void);
int ov_test_tool(void);
RECT ov_test_sel(void);
bool ov_test_click_button(int id);
bool ov_test_handle_point(int index, double *x, double *y); /* 1..8, the eight handles */
bool ov_test_click_palette(int index);                     /* 0..7 colours, 100+i sizes */
bool ov_test_type(const char *utf8);                       /* commit the inline text field */
#endif
