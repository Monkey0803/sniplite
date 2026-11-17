/* longscreen.h: the long screenshot's windows and sampling loop (src/scroll.c's UI half).
 * The stitching itself is stitch.c; this shows the region's frame, a bar with the output
 * buttons and a strip with the picture built so far, and reads the region a few times a
 * second. */
#pragma once

#include <stdbool.h>

#include "common.h" /* RECT */

/* Start the long screenshot of rc (global top-left points). The capture overlay must be
 * gone already: the first frame would otherwise contain it. */
bool long_begin(RECT rc);

/* End it now: copy the canvas to the pasteboard, save it to a chosen file, or pin it.
 * This is what the bar's buttons and Esc/Return do; also usable for tests and a CLI. */
void long_finish(bool copy, bool save, bool pin);
bool long_active(void);
void long_cancel(void);