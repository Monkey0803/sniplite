/* compat.m: the Windows calls that src/util.c, src/lang.c and src/config.c still make,
 * with the same meaning on macOS, plus the small helpers the ObjC side needs.
 *
 * Everything here is a shim with a narrow, documented contract. It is not a Windows
 * emulation layer: each function serves the shared sources only, and the platform
 * itself (screens, windows, drawing, IME, clipboard) is plain AppKit elsewhere. If a
 * later phase needs a shared file with a Windows API not listed here, add it here and
 * nowhere else. */
#import <Foundation/Foundation.h>

#include <ctype.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <malloc/malloc.h>
#include <mach/mach_time.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "plat.h"

/* ---- heap ------------------------------------------------------------------------ */

HANDLE GetProcessHeap(void) { return (HANDLE)1; }

void *HeapAlloc(HANDLE heap, DWORD flags, size_t n)
{
    (void)heap;
    if (!n)
        n = 1;
    return flags & HEAP_ZERO_MEMORY ? calloc(1, n) : malloc(n);
}

void *HeapReAlloc(HANDLE heap, DWORD flags, void *p, size_t n)
{
    (void)heap;
    if (!p)
        return HeapAlloc(heap, flags, n);
    if (!n)
        n = 1;
    size_t old = malloc_size(p);
    void *q = realloc(p, n);
    if (q && (flags & HEAP_ZERO_MEMORY) && n > old)
        memset((char *)q + old, 0, n - old);
    return q;
}

int HeapFree(HANDLE heap, DWORD flags, void *p)
{
    (void)heap;
    (void)flags;
    free(p);
    return TRUE;
}

/* ---- clock ----------------------------------------------------------------------- */

int QueryPerformanceFrequency(LARGE_INTEGER *f)
{
    f->QuadPart = 1000000000LL; /* nanoseconds */
    return TRUE;
}

int QueryPerformanceCounter(LARGE_INTEGER *c)
{
    c->QuadPart = (long long)mach_absolute_time();
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    /* ticks -> ns, keeping the frequency above honest */
    c->QuadPart = (long long)((double)c->QuadPart * (double)tb.numer / (double)tb.denom);
    return TRUE;
}

/* ---- strings --------------------------------------------------------------------- */

int CompareStringOrdinal(const WCHAR *a, int an, const WCHAR *b, int bn, int ignore_case)
{
    if (an < 0)
        an = (int)wcslen(a);
    if (bn < 0)
        bn = (int)wcslen(b);
    int n = an < bn ? an : bn;
    for (int i = 0; i < n; i++) {
        WCHAR x = a[i], y = b[i];
        if (ignore_case) {
            if (x >= L'a' && x <= L'z')
                x -= 32;
            if (y >= L'a' && y <= L'z')
                y -= 32;
        }
        if (x != y)
            return x < y ? 1 : 3; /* CSTR_LESS_THAN : CSTR_GREATER_THAN */
    }
    if (an == bn)
        return CSTR_EQUAL;
    return an < bn ? 1 : 3;
}

WCHAR *lstrcpynW(WCHAR *d, const WCHAR *s, int n)
{
    int i = 0;
    if (n <= 0)
        return d;
    for (; i < n - 1 && s[i]; i++)
        d[i] = s[i];
    d[i] = 0;
    return d;
}

/* wsprintfW/wvsprintfW: the conversions the shared sources use (d, i, u, x, X, s, c,
 * %%), with '-' and '0' flags, a width and a precision. Output is capped at 1023
 * characters like the Windows call; the callers' formats are short. */
static void put(WCHAR *buf, int cap, int *at, WCHAR c)
{
    if (*at < cap - 1) {
        buf[*at] = c;
        (*at)++;
    }
}

int snip_wvsprintf_va(WCHAR *buf, const WCHAR *fmt, va_list ap)
{
    const int cap = 1024;
    int at = 0;
    for (const WCHAR *p = fmt; *p; p++) {
        if (*p != L'%') {
            put(buf, cap, &at, *p);
            continue;
        }
        p++;
        if (*p == L'%') {
            put(buf, cap, &at, L'%');
            continue;
        }
        int left = 0, zero = 0, width = 0, prec = -1;
        while (*p == L'-' || *p == L'0') {
            if (*p == L'-')
                left = 1;
            else
                zero = 1;
            p++;
        }
        while (*p >= L'0' && *p <= L'9')
            width = width * 10 + (int)(*p++ - L'0');
        if (*p == L'.') {
            p++;
            prec = 0;
            while (*p >= L'0' && *p <= L'9')
                prec = prec * 10 + (int)(*p++ - L'0');
        }
        if (!*p)
            break;
        WCHAR tmp[256];
        int n = 0;
        switch (*p) {
        case L'd':
        case L'i': {
            int v = va_arg(ap, int);
            unsigned uv = (unsigned)(v < 0 ? -(long long)v : (long long)v);
            WCHAR dig[32];
            int dn = 0;
            do {
                dig[dn++] = (WCHAR)(L'0' + uv % 10);
            } while (uv /= 10);
            while (dn < prec)
                dig[dn++] = L'0';
            if (v < 0)
                tmp[n++] = L'-';
            for (int i = 0; i < dn; i++)
                tmp[n++] = dig[dn - 1 - i];
            break;
        }
        case L'u':
        case L'x':
        case L'X': {
            unsigned uv = va_arg(ap, unsigned int);
            unsigned base = *p == L'u' ? 10u : 16u;
            const WCHAR *hex = *p == L'X' ? L"0123456789ABCDEF" : L"0123456789abcdef";
            WCHAR dig[32];
            int dn = 0;
            do {
                unsigned d = uv % base;
                dig[dn++] = base == 10u ? (WCHAR)(L'0' + d) : hex[d];
            } while (uv /= base);
            while (dn < prec)
                dig[dn++] = L'0';
            for (int i = 0; i < dn; i++)
                tmp[n++] = dig[dn - 1 - i];
            break;
        }
        case L's': {
            const WCHAR *s = va_arg(ap, const WCHAR *);
            if (!s)
                s = L"(null)";
            int len = (int)wcslen(s);
            if (prec >= 0 && len > prec)
                len = prec;
            for (int i = 0; i < len; i++)
                tmp[n++] = s[i];
            break;
        }
        case L'c':
            tmp[n++] = (WCHAR)va_arg(ap, int);
            break;
        default:
            put(buf, cap, &at, L'%');
            put(buf, cap, &at, *p);
            continue;
        }
        /* a width with '0' pads after the sign, as printf does; otherwise spaces */
        int pad = width > n ? width - n : 0;
        int sign = n && (tmp[0] == L'-' || tmp[0] == L'+') ? 1 : 0;
        if (!left && zero && pad && sign) {
            put(buf, cap, &at, tmp[0]);
            for (int i = 0; i < pad; i++)
                put(buf, cap, &at, L'0');
            for (int i = sign; i < n; i++)
                put(buf, cap, &at, tmp[i]);
        } else {
            for (int i = 0; i < pad && !left; i++)
                put(buf, cap, &at, zero ? L'0' : L' ');
            for (int i = 0; i < n; i++)
                put(buf, cap, &at, tmp[i]);
            for (int i = 0; i < pad && left; i++)
                put(buf, cap, &at, L' ');
        }
    }
    buf[at] = 0;
    return at;
}

int snip_wsprintf(WCHAR *buf, const WCHAR *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = snip_wvsprintf_va(buf, fmt, ap);
    va_end(ap);
    return n;
}

/* ---- UTF-8 <-> WCHAR (UTF-32 here) ------------------------------------------------ */

static int utf8_decode(const unsigned char *s, int n, uint32_t *out, int max_out)
{
    int i = 0, o = 0;
    while (i < n && o < max_out) {
        unsigned char c = s[i];
        uint32_t cp;
        int extra;
        if (c < 0x80) {
            cp = c;
            extra = 0;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1F;
            extra = 1;
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0F;
            extra = 2;
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07;
            extra = 3;
        } else {
            return -1;
        }
        if (i + extra >= n)
            return -1;
        for (int k = 1; k <= extra; k++) {
            if ((s[i + k] & 0xC0) != 0x80)
                return -1;
            cp = (cp << 6) | (s[i + k] & 0x3F);
        }
        out[o++] = cp;
        i += extra + 1;
    }
    return o;
}

static int utf8_encode(uint32_t cp, char *dst, int cap)
{
    if (cp < 0x80) {
        if (cap < 1)
            return 0;
        dst[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        if (cap < 2)
            return 0;
        dst[0] = (char)(0xC0 | (cp >> 6));
        dst[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (cap < 3)
            return 0;
        dst[0] = (char)(0xE0 | (cp >> 12));
        dst[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        dst[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    if (cap < 4)
        return 0;
    dst[0] = (char)(0xF0 | (cp >> 18));
    dst[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    dst[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    dst[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

int MultiByteToWideChar(UINT cp, DWORD flags, const char *src, int n, WCHAR *dst, int cap)
{
    (void)flags;
    if (cp != CP_UTF8 || !src)
        return 0;
    bool terminated = n < 0;
    int len = terminated ? (int)strlen(src) : n;
    uint32_t *tmp = malloc(((size_t)len + 1) * sizeof(*tmp));
    if (!tmp)
        return 0;
    int cnt = utf8_decode((const unsigned char *)src, len, tmp, len);
    if (cnt < 0) {
        free(tmp);
        return 0;
    }
    int need = cnt + (terminated ? 1 : 0);
    if (dst && cap > 0) {
        int room = cap - (terminated ? 1 : 0);
        if (room < 0)
            room = 0;
        int k = cnt < room ? cnt : room;
        for (int i = 0; i < k; i++)
            dst[i] = (WCHAR)tmp[i];
        if (terminated)
            dst[k] = 0;
        need = k + (terminated ? 1 : 0);
    }
    free(tmp);
    return need;
}

int WideCharToMultiByte(UINT cp, DWORD flags, const WCHAR *src, int n, char *dst, int cap, const char *def, int *used)
{
    (void)flags;
    (void)def;
    if (used)
        *used = FALSE;
    if (cp != CP_UTF8 || !src)
        return 0;
    int len = n < 0 ? (int)wcslen(src) : n;
    int need = 0;
    for (int i = 0; i < len; i++) {
        char tmp[4];
        int k = utf8_encode((uint32_t)src[i], tmp, 4);
        if (dst && need + k <= cap)
            memcpy(dst + need, tmp, (size_t)k);
        need += k;
    }
    if (n < 0) {
        if (dst && need < cap)
            dst[need] = 0;
        need++;
    }
    return need;
}

/* ---- the settings file ------------------------------------------------------------ */

static NSString *home_dir(void)
{
    const char *h = getenv("HOME");
    if (h && *h)
        return [NSString stringWithUTF8String:h];
    return NSHomeDirectory();
}

void snip_support_dir(WCHAR *out, int cap)
{
    NSString *dir = [home_dir() stringByAppendingPathComponent:@"Library/Application Support/sniplite"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    MultiByteToWideChar(CP_UTF8, 0, [dir fileSystemRepresentation] ?: "", -1, out, cap);
}

void snip_ini_path(WCHAR *out, int cap)
{
    NSString *dir = [home_dir() stringByAppendingPathComponent:@"Library/Application Support/sniplite"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *file = [dir stringByAppendingPathComponent:@"sniplite.ini"];
    MultiByteToWideChar(CP_UTF8, 0, [file fileSystemRepresentation] ?: "", -1, out, cap);
}

static char *path_utf8(const WCHAR *w)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *b = malloc((size_t)n + 1);
    if (!b)
        return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, b, n, NULL, NULL);
    return b;
}

DWORD GetFileAttributesW(const WCHAR *path)
{
    char *p = path_utf8(path);
    if (!p)
        return INVALID_FILE_ATTRIBUTES;
    struct stat st;
    DWORD r = stat(p, &st) == 0 ? FILE_ATTRIBUTE_NORMAL : INVALID_FILE_ATTRIBUTES;
    free(p);
    return r;
}

/* Whole-file INI reader: enough for the keys config.c and lang.c read (an ASCII
 * [section] and key=value lines, written as UTF-8 by config_save). */
static char *read_text(const WCHAR *file, size_t *len)
{
    char *p = path_utf8(file);
    if (!p)
        return NULL;
    FILE *f = fopen(p, "rb");
    free(p);
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    if (n < 0) /* a read error: read nothing rather than allocate zero bytes */
        n = 0;
    fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)n + 1);
    if (!b) {
        fclose(f);
        return NULL;
    }
    size_t got = n > 0 ? fread(b, 1, (size_t)n, f) : 0;
    fclose(f);
    b[got] = 0;
    if (got >= 3 && (unsigned char)b[0] == 0xEF && (unsigned char)b[1] == 0xBB && (unsigned char)b[2] == 0xBF) {
        memmove(b, b + 3, got - 3);
        got -= 3;
    }
    *len = got;
    return b;
}

static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t')
        s++;
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\r' || s[n - 1] == '\n' || s[n - 1] == ' ' || s[n - 1] == '\t'))
        s[--n] = 0;
    return s;
}

static bool ascii_eq_nocase(const char *a, const char *b)
{
    for (; *a && *b; a++, b++)
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b))
            return false;
    return !*a && !*b;
}

/* NULL when the key is absent */
static char *ini_lookup(const WCHAR *file, const WCHAR *sec_w, const WCHAR *key_w)
{
    char *sec = path_utf8(sec_w), *key = path_utf8(key_w);
    size_t len = 0;
    char *text = read_text(file, &len);
    (void)len;
    char *found = NULL;
    if (text && sec && key) {
        bool in_section = false;
        for (char *line = text; line && *line;) {
            char *eol = strchr(line, '\n');
            if (eol)
                *eol = 0;
            char *t = trim(line);
            if (*t == '[') {
                char *close = strchr(t, ']');
                if (close) {
                    *close = 0;
                    in_section = ascii_eq_nocase(trim(t + 1), sec);
                }
            } else if (*t && *t != ';' && *t != '#' && in_section) {
                char *eq = strchr(t, '=');
                if (eq) {
                    *eq = 0;
                    if (ascii_eq_nocase(trim(t), key)) {
                        found = strdup(trim(eq + 1));
                        break;
                    }
                }
            }
            line = eol ? eol + 1 : NULL;
        }
    }
    free(text);
    free(sec);
    free(key);
    return found;
}

int GetPrivateProfileStringW(const WCHAR *sec, const WCHAR *key, const WCHAR *def, WCHAR *out, int cap, const WCHAR *file)
{
    char *v = ini_lookup(file, sec, key);
    if (!v) {
        if (def)
            lstrcpynW(out, def, cap);
        else if (cap > 0)
            out[0] = 0;
        return 0;
    }
    WCHAR *w = malloc((strlen(v) + 1) * sizeof(WCHAR));
    int n = 0;
    if (w) {
        MultiByteToWideChar(CP_UTF8, 0, v, -1, w, (int)strlen(v) + 1);
        n = (int)wcslen(w);
        lstrcpynW(out, w, cap);
        free(w);
    }
    free(v);
    return n < cap ? n : cap - 1;
}

UINT GetPrivateProfileIntW(const WCHAR *sec, const WCHAR *key, int def, const WCHAR *file)
{
    char *v = ini_lookup(file, sec, key);
    if (!v)
        return (UINT)def;
    UINT r = (UINT)atoi(v);
    free(v);
    return r;
}

HANDLE CreateFileW(const WCHAR *path, DWORD access, DWORD share, void *sa, DWORD how, DWORD flags, HANDLE tmpl)
{
    (void)share;
    (void)sa;
    (void)flags;
    (void)tmpl;
    char *p = path_utf8(path);
    if (!p)
        return INVALID_HANDLE_VALUE;
    FILE *f = fopen(p, access & GENERIC_WRITE ? (how == CREATE_ALWAYS ? "wb" : "r+b") : "rb");
    free(p);
    return f ? (HANDLE)f : INVALID_HANDLE_VALUE;
}

int WriteFile(HANDLE h, const void *buf, DWORD n, DWORD *written, void *ov)
{
    (void)ov;
    DWORD w = (DWORD)fwrite(buf, 1, n, (FILE *)h);
    if (written)
        *written = w;
    return w == n;
}

int CloseHandle(HANDLE h)
{
    return fclose((FILE *)h) == 0;
}

DWORD GetModuleFileNameW(HINSTANCE inst, WCHAR *out, DWORD cap)
{
    (void)inst;
    NSString *exe = [[NSBundle mainBundle] executablePath] ?: @"";
    MultiByteToWideChar(CP_UTF8, 0, [exe fileSystemRepresentation] ?: "", -1, out, (int)cap);
    return (DWORD)wcslen(out);
}

LANGID GetUserDefaultUILanguage(void)
{
    NSString *code = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    if ([code hasPrefix:@"zh-Hant"] || [code hasPrefix:@"zh-TW"] || [code hasPrefix:@"zh-HK"] ||
        [code hasPrefix:@"zh-MO"])
        return LANG_CHINESE | (SUBLANG_CHINESE_TRADITIONAL << 10);
    if ([code hasPrefix:@"zh"])
        return LANG_CHINESE;
    if ([code hasPrefix:@"ja"])
        return LANG_JAPANESE;
    if ([code hasPrefix:@"ko"])
        return LANG_KOREAN;
    if ([code hasPrefix:@"fr"])
        return LANG_FRENCH;
    if ([code hasPrefix:@"de"])
        return LANG_GERMAN;
    if ([code hasPrefix:@"es"])
        return LANG_SPANISH;
    return LANG_ENGLISH;
}

/* ---- Img ------------------------------------------------------------------------- */

bool img_create(Img *im, int w, int h)
{
    memset(im, 0, sizeof *im);
    if (w <= 0 || h <= 0 || (int64_t)w * h > ((int64_t)1 << 28))
        return false;
    uint32_t *px = calloc((size_t)w * (size_t)h, 4);
    if (!px)
        return false;
    /* BGRX: the alpha byte is unused but opaque, so a straight CGImage of it is sane */
    for (size_t i = 0, n = (size_t)w * (size_t)h; i < n; i++)
        px[i] = 0xFF000000u;
    im->px = px;
    im->w = w;
    im->h = h;
    return true;
}

void img_destroy(Img *im)
{
    free(im->px);
    memset(im, 0, sizeof *im);
}

/* ---- bridging -------------------------------------------------------------------- */

WCHAR *snip_utf8_to_wstr(const char *utf8)
{
    if (!utf8)
        return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (n <= 0)
        return NULL;
    WCHAR *w = malloc((size_t)n * sizeof(WCHAR));
    if (w)
        MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n);
    return w;
}

char *snip_wstr_to_utf8_len(const WCHAR *s, int n)
{
    if (!s)
        return NULL;
    int bytes = WideCharToMultiByte(CP_UTF8, 0, s, n, NULL, 0, NULL, NULL);
    if (bytes < 0)
        return NULL;
    char *b = malloc((size_t)bytes + 1);
    if (!b)
        return NULL;
    WideCharToMultiByte(CP_UTF8, 0, s, n, b, bytes, NULL, NULL);
    b[bytes] = 0;
    return b;
}

char *snip_wstr_to_utf8(const WCHAR *s)
{
    return s ? snip_wstr_to_utf8_len(s, (int)wcslen(s)) : NULL;
}

/* ---- log ------------------------------------------------------------------------- */

void snip_log(const char *fmt, ...)
{
    static FILE *f;
    static bool tried;
    if (!tried) {
        tried = true;
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        NSString *file = [dir stringByAppendingPathComponent:@"sniplite.log"];
        f = fopen([file fileSystemRepresentation], "a");
    }
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tm);
    if (f) {
        fprintf(f, "%s  %s\n", stamp, line);
        fflush(f);
    }
    fprintf(stderr, "[sniplite %s] %s\n", stamp, line);
}
