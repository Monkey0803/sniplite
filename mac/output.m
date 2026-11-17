/* output.m: crop, pasteboard and image files.
 *
 * Windows builds this on WIC and the OLE clipboard (src/image.S); here it is ImageIO and
 * NSPasteboard. The pixel work stays the same: the selection is sampled out of the
 * frozen tiles by nearest neighbour, at the scale of the display under the selection's
 * top-left corner. */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "annotate.h"
#include "common.h"
#include "output.h"

static void free_provider_data(void *info, const void *data, size_t size)
{
    (void)info;
    (void)size;
    free((void *)data);
}

static const SnipTile *tile_at_point(const SnipShot *shot, long x, long y)
{
    for (int i = 0; i < shot->ntile; i++)
        if (rect_has(&shot->tile[i].rc, (int)x, (int)y))
            return &shot->tile[i];
    return shot->ntile ? &shot->tile[0] : NULL;
}

static uint32_t sample(const SnipTile *t, long gx, long gy)
{
    double fx = (double)(gx - t->rc.left) * t->scale;
    double fy = (double)(gy - t->rc.top) * t->scale;
    int x = fx >= 0 ? (int)fx : 0;
    int y = fy >= 0 ? (int)fy : 0;
    if (x >= t->w)
        x = t->w - 1;
    if (y >= t->h)
        y = t->h - 1;
    return t->px[(size_t)y * (size_t)t->w + (size_t)x];
}

CGImageRef out_crop(const SnipShot *shot, RECT sel)
{
    RECT r = rect_isect(sel, shot->vs);
    if (rect_empty(&r))
        return NULL;
    const SnipTile *origin = tile_at_point(shot, r.left + (r.right - r.left) / 2, r.top + (r.bottom - r.top) / 2);
    const SnipTile *corner = tile_at_point(shot, r.left, r.top);
    if (!origin)
        return NULL;
    float scale = corner ? corner->scale : origin->scale;
    int w = (int)lround((r.right - r.left) * scale);
    int h = (int)lround((r.bottom - r.top) * scale);
    if (w < 1 || h < 1)
        return NULL;
    uint32_t *px = malloc((size_t)w * (size_t)h * 4);
    if (!px)
        return NULL;
    for (int y = 0; y < h; y++) {
        long gy = r.top + (long)floor((y + 0.5) / scale);
        for (int x = 0; x < w; x++) {
            long gx = r.left + (long)floor((x + 0.5) / scale);
            const SnipTile *t = tile_at_point(shot, gx, gy);
            px[(size_t)y * (size_t)w + (size_t)x] = t ? sample(t, gx, gy) : 0xFF000000u;
        }
    }
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, px, (size_t)w * (size_t)h * 4, free_provider_data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs,
                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, prov, NULL, false,
                                   kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(prov);
    return img; /* the provider owns and frees px */
}

static NSData *encode(CGImageRef img, NSString *type, double quality)
{
    NSMutableData *d = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)d,
                                                                 (__bridge CFStringRef)type, 1, NULL);
    if (!dst)
        return nil;
    NSDictionary *opts = quality >= 0 ? @{(id)kCGImageDestinationLossyCompressionQuality : @(quality)} : @{};
    CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)opts);
    bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? d : nil;
}

static bool file_type_for(NSString *path, CFStringRef *type, double *quality)
{
    NSString *ext = path.pathExtension.lowercaseString;
    *quality = -1;
    if ([ext isEqualToString:@"png"]) {
        *type = (__bridge CFStringRef)UTTypePNG.identifier;
    } else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
        *type = (__bridge CFStringRef)UTTypeJPEG.identifier;
        *quality = 0.92;
    } else if ([ext isEqualToString:@"tif"] || [ext isEqualToString:@"tiff"]) {
        *type = (__bridge CFStringRef)UTTypeTIFF.identifier;
    } else if ([ext isEqualToString:@"bmp"]) {
        *type = (__bridge CFStringRef)UTTypeBMP.identifier;
    } else {
        return false;
    }
    return true;
}

CGImageRef out_crop_annotated(const SnipShot *shot, RECT sel, const AnnoList *annos)
{
    CGImageRef base = out_crop(shot, sel);
    if (!base)
        return NULL;
    if (!annos || anno_count(annos) == 0)
        return base;
    size_t w = CGImageGetWidth(base), h = CGImageGetHeight(base);
    if (!w || !h) {
        CGImageRelease(base);
        return NULL;
    }
    double scale = (double)w / MAX(1.0, (double)(sel.right - sel.left));
    uint32_t *px = calloc(w * h, 4);
    if (!px) {
        CGImageRelease(base);
        return NULL;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(px, w, h, 8, w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!cg) {
        free(px);
        CGImageRelease(base);
        return NULL;
    }
    CGContextSetBlendMode(cg, kCGBlendModeCopy);
    CGContextDrawImage(cg, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), base);
    CGContextSetBlendMode(cg, kCGBlendModeNormal);
    CGContextTranslateCTM(cg, 0, (CGFloat)h);
    CGContextScaleCTM(cg, (CGFloat)scale, (CGFloat)-scale);
    anno_render(cg, annos, shot, sel);
    CGImageRef out = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    free(px);
    CGImageRelease(base);
    return out;
}

bool out_copy(const SnipShot *shot, RECT sel)
{
    CGImageRef img = out_crop(shot, sel);
    if (!img)
        return false;
    NSData *png = encode(img, UTTypePNG.identifier, -1);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSData *tiff = [rep representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    bool ok = png && [pb setData:png forType:NSPasteboardTypePNG];
    if (tiff)
        [pb setData:tiff forType:NSPasteboardTypeTIFF];
    CGImageRelease(img);
    snip_log("copied %ldx%ld points as PNG%s", (long)(sel.right - sel.left), (long)(sel.bottom - sel.top),
             ok ? "" : " (FAILED)");
    return ok;
}

static bool write_image(CGImageRef img, NSString *path)
{
    CFStringRef type = NULL;
    double quality = -1;
    if (!file_type_for(path, &type, &quality))
        return false;
    NSData *data = encode(img, (__bridge NSString *)type, quality);
    return data ? [data writeToFile:path atomically:YES] : false;
}

bool out_write_image(CGImageRef img, NSString *path)
{
    return img ? write_image(img, path) : false;
}

bool out_copy_annotated(const SnipShot *shot, RECT sel, const AnnoList *annos)
{
    CGImageRef img = out_crop_annotated(shot, sel, annos);
    if (!img)
        return false;
    NSData *png = encode(img, UTTypePNG.identifier, -1);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSData *tiff = [rep representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}];
    CGImageRelease(img);
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    bool ok = png && [pb setData:png forType:NSPasteboardTypePNG];
    if (tiff)
        [pb setData:tiff forType:NSPasteboardTypeTIFF];
    snip_log("copied %ldx%ld points with %d annotations%s", (long)(sel.right - sel.left),
             (long)(sel.bottom - sel.top), anno_count(annos), ok ? "" : " (FAILED)");
    return ok;
}

bool out_save_annotated(const SnipShot *shot, RECT sel, const AnnoList *annos, NSString *path)
{
    CGImageRef img = out_crop_annotated(shot, sel, annos);
    if (!img)
        return false;
    bool ok = write_image(img, path);
    CGImageRelease(img);
    return ok;
}

bool out_save(const SnipShot *shot, RECT sel, NSString *path)
{
    CFStringRef type = NULL;
    double quality = -1;
    if (!file_type_for(path, &type, &quality))
        return false;
    CGImageRef img = out_crop(shot, sel);
    if (!img)
        return false;
    NSData *data = encode(img, (__bridge NSString *)type, quality);
    CGImageRelease(img);
    if (!data)
        return false;
    return [data writeToFile:path atomically:YES];
}
