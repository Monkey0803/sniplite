/* stitch.c: the stitching of the long screenshot (src/scroll.c's algorithm, the same
 * constants and the same decisions). Only the platform changed: the canvas grows with
 * realloc instead of a reserved VirtualAlloc range, and the windows, timers and
 * thumbnails are longscreen.m's job. */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "stitch.h"

#define STRIPS 8

typedef struct {
    uint32_t key;
    int32_t n;
    int32_t row[3];
} Slot;

typedef struct {
    Slot *table;
    int tsize;
    int *vote;
    int nbin;
} Priv;

static inline uint32_t strip_hash(const uint32_t *p, int n)
{
    uint64_t a = 0x9E3779B97F4A7C15ull, b = 0xC2B2AE3D27D4EB4Full, v;
    int i = 0;
    for (; i + 4 <= n; i += 4) {
        memcpy(&v, p + i, 8);
        a = (a ^ v) * 0xFF51AFD7ED558CCDull;
        memcpy(&v, p + i + 2, 8);
        b = (b ^ v) * 0xC4CEB9FE1A85EC53ull;
    }
    for (; i < n; i++)
        a = (a ^ p[i]) * 0xFF51AFD7ED558CCDull;
    a = (a ^ (b >> 32 | b << 32)) * 0x9E3779B97F4A7C15ull;
    uint32_t h = (uint32_t)(a >> 32);
    return h + !h; /* 0 marks a free slot */
}

static inline Slot *slot_of(const Priv *p, uint32_t key)
{
    unsigned mask = (unsigned)p->tsize - 1, i = key & mask;
    while (p->table[i].key && p->table[i].key != key)
        i = (i + 1) & mask;
    return &p->table[i];
}

static void hash_frame(Stitch *s, const uint32_t *px)
{
    for (int y = 0; y < s->h; y++) {
        const uint32_t *row = px + (size_t)y * (size_t)s->w + (size_t)s->x0;
        uint32_t *out = s->fhash + (size_t)y * STRIPS;
        for (int k = 0; k < STRIPS; k++)
            out[k] = strip_hash(row + (size_t)k * (size_t)s->seg, s->seg);
    }
}

/* Where on the canvas this frame's top row is; false when it cannot be told. */
static bool place(Stitch *s, int *at)
{
    Priv *p = s->priv;
    int h = s->h, base = s->pos - h;
    int lo = s->pos - h > 0 ? s->pos - h : 0;
    int hi = s->pos + 2 * h < s->rows ? s->pos + 2 * h : s->rows;
    memset(p->vote, 0, (size_t)p->nbin * sizeof(int));
    for (int k = 0; k < STRIPS; k++) {
        memset(p->table, 0, (size_t)p->tsize * sizeof(Slot));
        for (int r = lo; r < hi; r++) {
            uint32_t key = s->chash[(size_t)r * STRIPS + k];
            Slot *e = slot_of(p, key);
            e->key = key;
            if (e->n < 3)
                e->row[e->n] = r;
            e->n++;
        }
        for (int y = 0; y < h; y++) {
            uint32_t key = s->fhash[(size_t)y * STRIPS + k];
            if (key == s->phash[(size_t)y * STRIPS + k])
                continue; /* did not move since the frame before: no vote */
            const Slot *e = slot_of(p, key);
            if (!e->key || e->n > 3)
                continue; /* nowhere near, or everywhere: no information */
            for (int j = 0; j < e->n; j++) {
                int bin = e->row[j] - y - base;
                if (bin >= 0 && bin < p->nbin)
                    p->vote[bin]++;
            }
        }
    }
    int best = -1, most = 0, next = 0, need = h / 8 > 16 ? h / 8 : 16;
    for (int i = 0; i < p->nbin; i++)
        if (p->vote[i] > most) {
            most = p->vote[i];
            best = i;
        }
    for (int i = 0; i < p->nbin; i++)
        if (i != best && p->vote[i] > next)
            next = p->vote[i];
    if (most >= need && most >= 2 * next) {
        *at = base + best;
        return true;
    }
    /* What changed is nowhere near on the canvas: still in place when the frame looks
     * like what the canvas already has there. */
    int same = 0, all = 0;
    for (int y = 0; y < h && s->pos + y < s->rows; y++) {
        if (s->pos + y < 0)
            continue;
        const uint32_t *f = s->fhash + (size_t)y * STRIPS, *c = s->chash + (size_t)(s->pos + y) * STRIPS;
        for (int k = 0; k < STRIPS; k++)
            same += f[k] == c[k];
        all += STRIPS;
    }
    *at = s->pos;
    return s->rows > 0 && all && same * 4 >= all;
}

static bool grow(Stitch *s, int rows)
{
    if (rows <= s->cap)
        return true;
    int cap = s->cap ? s->cap * 2 : s->h * 2;
    if (cap < rows)
        cap = rows;
    if (cap > s->max_rows)
        cap = s->max_rows;
    if (cap < rows)
        return false;
    uint32_t *c = realloc(s->canvas, (size_t)cap * (size_t)s->w * 4);
    if (!c)
        return false;
    s->canvas = c;
    s->cap = cap;
    return true;
}

/* n rows from the frame's row y onto the end of the canvas, with the frame's hashes. */
static int append_from(Stitch *s, const uint32_t *px, int y, int n)
{
    n = n < s->max_rows - s->rows ? n : s->max_rows - s->rows;
    if (n <= 0 || y < 0 || y + n > s->h)
        return 0;
    if (!grow(s, s->rows + n))
        return 0;
    memcpy(s->canvas + (size_t)s->rows * (size_t)s->w, px + (size_t)y * (size_t)s->w,
           (size_t)n * (size_t)s->w * 4);
    memcpy(s->chash + (size_t)s->rows * STRIPS, s->fhash + (size_t)y * STRIPS, (size_t)n * STRIPS * sizeof(uint32_t));
    s->rows += n;
    return n;
}

int stitch_feed(Stitch *s, const uint32_t *px)
{
    hash_frame(s, px);
    int rows0 = s->rows;

    if (s->first) {
        s->first = false;
        append_from(s, px, 0, s->h);
    } else if (!memcmp(s->fhash, s->phash, (size_t)s->h * STRIPS * sizeof(uint32_t))) {
        return 0; /* the same frame: the page did not move */
    } else {
        int at = 0;
        s->lost = !place(s, &at);
        if (!s->lost && at != s->pos) {
            int foot = 0; /* rows at the bottom that stayed while the rest moved */
            while (foot < s->h / 2 &&
                   !memcmp(s->fhash + (size_t)(s->h - 1 - foot) * STRIPS,
                           s->phash + (size_t)(s->h - 1 - foot) * STRIPS, STRIPS * sizeof(uint32_t)))
                foot++;
            int keep = s->pos + s->h - foot;
            if (foot && s->rows > keep && s->rows <= s->pos + s->h && keep > 0)
                s->rows = keep; /* they were appended as if they belonged there */
            s->pos = at;
            int from = s->rows - at;
            int want = at + s->h - foot - s->rows;
            if (from < 0)
                from = 0;
            if (want > 0 && from < s->h)
                append_from(s, px, from, want);
        }
    }

    if (s->rows >= s->max_rows)
        s->full = true;
    /* the last frame, kept for stitch_finish: the footer that was held back */
    if (!s->last) {
        s->last = malloc((size_t)s->w * (size_t)s->h * 4);
        if (!s->last)
            return s->rows - rows0;
    }
    memcpy(s->last, px, (size_t)s->w * (size_t)s->h * 4);
    uint32_t *t = s->fhash;
    s->fhash = s->phash;
    s->phash = t;
    return s->rows - rows0;
}

void stitch_finish(Stitch *s)
{
    if (!s->last || s->lost || s->first)
        return;
    int rest = s->rows - s->pos;
    if (rest < 0 || rest >= s->h)
        return;
    /* the last frame's rows below the canvas are the footer that stayed put */
    int want = s->h - rest;
    if (want <= 0 || !grow(s, s->rows + want))
        return;
    int n = want < s->max_rows - s->rows ? want : s->max_rows - s->rows;
    if (n <= 0)
        return;
    memcpy(s->canvas + (size_t)s->rows * (size_t)s->w, s->last + (size_t)rest * (size_t)s->w,
           (size_t)n * (size_t)s->w * 4);
    memcpy(s->chash + (size_t)s->rows * STRIPS, s->phash + (size_t)rest * STRIPS, (size_t)n * STRIPS * sizeof(uint32_t));
    s->rows += n;
}

int stitch_rows(const Stitch *s) { return s->rows; }
const uint32_t *stitch_canvas(const Stitch *s) { return s->canvas; }

bool stitch_init(Stitch *s, int w, int h)
{
    memset(s, 0, sizeof *s);
    if (w < 16 || h < 16)
        return false;
    Priv *p = calloc(1, sizeof *p);
    if (!p)
        return false;
    s->priv = p;
    s->w = w;
    s->h = h;
    s->max_rows = 32768 < 40000000 / w ? 32768 : 40000000 / w;
    if (s->max_rows < 2 * h)
        s->max_rows = 2 * h;
    s->x0 = w / 16;
    s->seg = (w - 2 * s->x0) / STRIPS;
    if (s->seg < 1)
        s->seg = 1;
    for (p->tsize = 1024; p->tsize < 6 * h; p->tsize *= 2)
        ;
    p->nbin = 2 * h + 1;
    p->table = calloc((size_t)p->tsize, sizeof(Slot));
    p->vote = calloc((size_t)p->nbin, sizeof(int));
    s->chash = calloc((size_t)s->max_rows * STRIPS, sizeof(uint32_t));
    s->fhash = calloc((size_t)h * STRIPS, sizeof(uint32_t));
    s->phash = calloc((size_t)h * STRIPS, sizeof(uint32_t));
    s->first = true;
    return p->table && p->vote && s->chash && s->fhash && s->phash;
}

void stitch_free(Stitch *s)
{
    Priv *p = s->priv;
    if (p) {
        free(p->table);
        free(p->vote);
        free(p);
    }
    free(s->canvas);
    free(s->chash);
    free(s->fhash);
    free(s->phash);
    free(s->last);
    memset(s, 0, sizeof *s);
}