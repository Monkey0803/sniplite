/* pin.h: pinned images on top of the other windows (src/pin.c on Windows).
 *
 * A pin is a borderless panel that shows a CGImage, can be dragged, zoomed with the
 * wheel, made more or less opaque with Cmd+wheel, and closed with a double click, Esc or
 * its menu. Pins are independent of the capture overlay: the overlay renders its image
 * and hands it over. */
#pragma once

#include <CoreGraphics/CoreGraphics.h>

#include <stdbool.h>

/* Show img pinned at (x, y) in global top-left points; the image is retained. */
void pin_create(CGImageRef img, int x, int y);

/* Pin the image (or the text, rendered to an image) from the clipboard. False when the
 * clipboard holds nothing usable. */
bool pin_from_clipboard(void);

int pin_count(void);
void pin_toggle_all(void); /* hide them all, or show them again */
bool pin_all_hidden(void);
void pin_close_all(void);
void pin_refresh_levels(void); /* "keep every pin on top" changed in the settings */
void pin_set_top(bool on);
void pin_set_top(bool on);     /* the setting, before the first pin exists */

#ifdef SNIPLITE_TEST
/* The pins' internals for the UI test (-DSNIPLITE_TEST only). */
double pin_test_zoom_last(double factor, double *width); /* < 0 when there is no pin */
double pin_test_alpha_last(void);
int pin_test_level_last(void);
#endif
