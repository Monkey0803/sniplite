/* plat.h: the small Windows surface the reused C files of src/ still ask for.
 *
 * The macOS port keeps the portable C of the Windows build (lang.c, config.c, util.c,
 * and in later phases scroll.c / ocr*.c) and gives it this header instead of
 * <windows.h>. Nothing here is a Windows emulator: only the handful of names those
 * files actually use, with the same meaning, implemented in compat.m on top of libc
 * and Foundation. Everything platform-shaped (windows, screens, drawing, clipboard)
 * lives in the mac/ ObjC files and never comes through here.
 *
 * WCHAR is wchar_t (32-bit on macOS) and not uint16_t, so the L"..." literals of the
 * shared sources keep working. UTF-16 does not exist on this side: anything going to
 * or coming from AppKit is converted with snip_wstr_* below.
 *
 * Only for __APPLE__ sources: the Windows build never sees this file. */
#pragma once

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

/* ---- base types --------------------------------------------------------------- */
typedef wchar_t WCHAR;
typedef uint32_t UINT;
typedef uint32_t DWORD;
typedef int32_t LONG;
typedef int32_t HRESULT;
typedef void *HANDLE;
typedef void *HWND;
typedef void *HMONITOR;
typedef void *HINSTANCE;
typedef void *HICON;
typedef uint16_t LANGID;

#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif

#define MAX_PATH 1024

typedef struct {
    LONG left, top, right, bottom;
} RECT;

typedef struct {
    LONG x, y;
} POINT;

/* The Windows files use a top-down 32bpp BGRX buffer; keep the same contract.
 * The drawing target (Surf, draw.h) points into px with stride == w. */
typedef struct {
    uint32_t *px;
    int w, h;
} Img;

bool img_create(Img *im, int w, int h);
void img_destroy(Img *im);

/* ---- small constants the shared sources name ------------------------------------ */

#define CP_UTF8 65001u
#define CSTR_EQUAL 2
#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)
#define INVALID_HANDLE_VALUE ((HANDLE)-1)
#define GENERIC_WRITE 0x40000000u
#define CREATE_ALWAYS 2u
#define FILE_ATTRIBUTE_NORMAL 0x80u
#define HEAP_ZERO_MEMORY 0x8u

/* hotkey modifiers, as in hotkey_parse/hotkey_format (config.c) */
#define MOD_ALT 0x1u
#define MOD_CONTROL 0x2u
#define MOD_SHIFT 0x4u
#define MOD_WIN 0x8u

/* The virtual-key numbers only have to be stable inside the ini and the code: hotkey.c
 * maps them to Carbon key codes. The values are the Windows ones so a sniplite.ini
 * written on Windows keeps meaning the same keys here. */
#define VK_TAB 0x09u
#define VK_PAUSE 0x13u
#define VK_SPACE 0x20u
#define VK_PRIOR 0x21u
#define VK_NEXT 0x22u
#define VK_END 0x23u
#define VK_HOME 0x24u
#define VK_LEFT 0x25u
#define VK_UP 0x26u
#define VK_RIGHT 0x27u
#define VK_DOWN 0x28u
#define VK_SNAPSHOT 0x2Cu
#define VK_INSERT 0x2Du
#define VK_DELETE 0x2Eu
#define VK_NUMPAD0 0x60u
#define VK_NUMPAD9 0x69u
#define VK_F1 0x70u
#define VK_F24 0x87u
#define VK_SCROLL 0x91u
#define VK_OEM_3 0xC0u

/* GetUserDefaultUILanguage(): the Windows LANGID of the macOS locale, so that
 * lang_system() in lang.c keeps its switch unchanged. */
#define LANG_ENGLISH 0x09u
#define LANG_FRENCH 0x0Cu
#define LANG_GERMAN 0x07u
#define LANG_JAPANESE 0x11u
#define LANG_KOREAN 0x12u
#define LANG_SPANISH 0x0Au
#define LANG_CHINESE 0x04u
#define SUBLANG_CHINESE_TRADITIONAL 0x01u
#define SUBLANG_CHINESE_HONGKONG 0x03u
#define SUBLANG_CHINESE_MACAU 0x05u
#define PRIMARYLANGID(id) ((LANGID)((id) & 0x3FFu))
#define SUBLANGID(id) ((LANGID)((id) >> 10))

/* ---- the calls the reused sources make ------------------------------------------ */

/* util.c: memory, clock, string compare. */
HANDLE GetProcessHeap(void);
void *HeapAlloc(HANDLE heap, DWORD flags, size_t n);
void *HeapReAlloc(HANDLE heap, DWORD flags, void *p, size_t n);
int HeapFree(HANDLE heap, DWORD flags, void *p);

typedef struct {
    long long QuadPart;
} LARGE_INTEGER;
int QueryPerformanceFrequency(LARGE_INTEGER *f);
int QueryPerformanceCounter(LARGE_INTEGER *c);

int CompareStringOrdinal(const WCHAR *a, int an, const WCHAR *b, int bn, int ignore_case);

int snip_wsprintf(WCHAR *buf, const WCHAR *fmt, ...);
int snip_wvsprintf_va(WCHAR *buf, const WCHAR *fmt, va_list ap);
#define wsprintfW snip_wsprintf
#define wvsprintfW snip_wvsprintf_va

/* The lstr* family, on the 32-bit WCHAR above. */
static inline int lstrlenW(const WCHAR *s) { return (int)wcslen(s); }
static inline WCHAR *lstrcpyW(WCHAR *d, const WCHAR *s) { return wcscpy(d, s); }
static inline WCHAR *lstrcatW(WCHAR *d, const WCHAR *s) { return wcscat(d, s); }
static inline int lstrcmpW(const WCHAR *a, const WCHAR *b) { return wcscmp(a, b); }
WCHAR *lstrcpynW(WCHAR *d, const WCHAR *s, int n);

int MultiByteToWideChar(UINT cp, DWORD flags, const char *src, int n, WCHAR *dst, int cap);
int WideCharToMultiByte(UINT cp, DWORD flags, const WCHAR *src, int n, char *dst, int cap, const char *def, int *used);

/* lang.c / config.c: the settings file, and where it lives. */
DWORD GetFileAttributesW(const WCHAR *path);
int GetPrivateProfileStringW(const WCHAR *sec, const WCHAR *key, const WCHAR *def, WCHAR *out, int cap, const WCHAR *file);
UINT GetPrivateProfileIntW(const WCHAR *sec, const WCHAR *key, int def, const WCHAR *file);
HANDLE CreateFileW(const WCHAR *path, DWORD access, DWORD share, void *sa, DWORD how, DWORD flags, HANDLE tmpl);
int WriteFile(HANDLE h, const void *buf, DWORD n, DWORD *written, void *ov);
int CloseHandle(HANDLE h);
DWORD GetModuleFileNameW(HINSTANCE inst, WCHAR *out, DWORD cap);
LANGID GetUserDefaultUILanguage(void);

/* ---- the macOS side of the port ------------------------------------------------ */

/* ~/Library/Application Support/sniplite/sniplite.ini */
void snip_ini_path(WCHAR *out, int cap);
/* ~/Library/Application Support/sniplite (created on demand) */
void snip_support_dir(WCHAR *out, int cap);

/* The only bridge between the shared WCHAR strings and UTF-8. Both return malloc'd
 * memory (free() it): the ObjC side wraps it in NSString, never a void* object. */
WCHAR *snip_utf8_to_wstr(const char *utf8);
char *snip_wstr_to_utf8(const WCHAR *s);
char *snip_wstr_to_utf8_len(const WCHAR *s, int n);

void snip_log(const char *fmt, ...);
