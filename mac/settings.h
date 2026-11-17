/* settings.h: the preferences window (src/settings.c on Windows; four pages here). */
#pragma once

#include <stdbool.h>

/* Posted when a preference was written to sniplite.ini, so the app re-registers the
 * hotkeys, rebuilds its menu and moves the pins' level. userInfo[@"ok"] is an NSArray of
 * NSNumber (0/1) per HK_*, posted again by the app when the hotkeys were registered. */
extern NSString *const SnipConfigChangedNotification;
/* Posted by the app after it re-registered the hotkeys; userInfo[@"ok"] is an NSArray of
 * NSNumber per HK_*. The hotkey page turns those into its status labels. */
extern NSString *const SnipHotkeysChangedNotification;

void settings_open(void);
bool settings_visible(void);