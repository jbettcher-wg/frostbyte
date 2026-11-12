/*
 * FrostByte: a Cocoa WPEPlatform backend for Mac OS X 10.5 (ppc64).
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 *
 * WPEDisplayCocoa  - NSApplication, creates views and toplevels, pumps Cocoa events from GLib.
 * WPEToplevelCocoa - one NSWindow per toplevel (textured: unified title bar and toolbar).
 * WPEViewCocoa     - an NSView that shows WPE shared-memory frames through CoreGraphics
 *                    (native 0xAARRGGBB words = kCGImageAlphaPremultipliedFirst |
 *                    kCGBitmapByteOrder32Host) and turns NSEvents into WPE events.
 * WPEKeymapCocoa   - keyboard events carry their keysym directly, so no XKB data is needed.
 */
#ifndef FROSTBYTE_WPE_COCOA_H
#define FROSTBYTE_WPE_COCOA_H

#include <wpe/wpe-platform.h>

G_BEGIN_DECLS

#define WPE_TYPE_DISPLAY_COCOA (wpe_display_cocoa_get_type())
G_DECLARE_FINAL_TYPE(WPEDisplayCocoa, wpe_display_cocoa, WPE, DISPLAY_COCOA, WPEDisplay)

#define WPE_TYPE_TOPLEVEL_COCOA (wpe_toplevel_cocoa_get_type())
G_DECLARE_FINAL_TYPE(WPEToplevelCocoa, wpe_toplevel_cocoa, WPE, TOPLEVEL_COCOA, WPEToplevel)

#define WPE_TYPE_VIEW_COCOA (wpe_view_cocoa_get_type())
G_DECLARE_FINAL_TYPE(WPEViewCocoa, wpe_view_cocoa, WPE, VIEW_COCOA, WPEView)

#define WPE_TYPE_KEYMAP_COCOA (wpe_keymap_cocoa_get_type())
G_DECLARE_FINAL_TYPE(WPEKeymapCocoa, wpe_keymap_cocoa, WPE, KEYMAP_COCOA, WPEKeymap)

WPEDisplay *wpe_display_cocoa_new(void);

/* The NSWindow (as void*, so C callers need no Objective-C) and the NSView of a view. */
void *wpe_toplevel_cocoa_get_window(WPEToplevelCocoa *toplevel);
void *wpe_view_cocoa_get_nsview(WPEViewCocoa *view);

/* Put this toplevel's views inside @host (an NSView in its window) instead of making each one the
 * window's content view. Every view fills the host; WPEView:visible decides which one shows. */
void wpe_toplevel_cocoa_set_view_host(WPEToplevelCocoa *toplevel, void *host);

/* Called when the user clicks the window's close button. Returning FALSE keeps the window open (the
 * application may then close it itself, e.g. after asking); without a function it closes. */
typedef gboolean (*WPEToplevelCocoaShouldCloseFunc)(WPEToplevelCocoa *toplevel, gpointer userData);
void wpe_toplevel_cocoa_set_should_close_func(WPEToplevelCocoa *toplevel, WPEToplevelCocoaShouldCloseFunc func,
                                              gpointer userData);

G_END_DECLS

#endif
