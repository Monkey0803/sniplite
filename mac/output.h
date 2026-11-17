/* output.h: the selection out of a SnipShot: a CGImage, the pasteboard and image files.
 *
 * Phase 2 only copies; saving and pinning arrive with Phase 4, on the same crop. */
#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdbool.h>

#include "annotate.h"
#include "capture.h"

/* Crop sel (global top-left points) out of the shot. The pixels come from the display
 * at the selection's top-left corner, at that display's scale; a selection that crosses
 * displays is sampled through each tile. NULL when the rect is empty. Caller releases. */
CGImageRef out_crop(const SnipShot *shot, RECT sel) CF_RETURNS_RETAINED;

/* Put the selection on the general pasteboard as PNG (and TIFF for older apps). */
bool out_copy(const SnipShot *shot, RECT sel);

/* Write the selection to a file, by its extension (png, jpg/jpeg, bmp, tiff). */
bool out_save(const SnipShot *shot, RECT sel, NSString *path);

/* Write an image to a file, by its extension. */
bool out_write_image(CGImageRef img, NSString *path);

/* The same with the annotations painted on top (Phase 3). */
CGImageRef out_crop_annotated(const SnipShot *shot, RECT sel, const AnnoList *annos) CF_RETURNS_RETAINED;
bool out_copy_annotated(const SnipShot *shot, RECT sel, const AnnoList *annos);
bool out_save_annotated(const SnipShot *shot, RECT sel, const AnnoList *annos, NSString *path);
