/*
 * FrostByte Cocoa backend: the EGL display (kept out of wpe-cocoa.m because libepoxy and
 * Cocoa's OpenGL headers cannot share a translation unit).
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include <epoxy/egl.h>
#include <wpe/wpe-platform.h>

/* CPU tier: hand WebKit LeopardEGL's surfaceless display, as the headless backend does. */
gpointer frostbyte_cocoa_get_egl_display(WPEDisplay *display, GError **error);
gpointer frostbyte_cocoa_get_egl_display(WPEDisplay *display, GError **error)
{
    (void)display;
    if (!epoxy_has_egl_extension(NULL, "EGL_MESA_platform_surfaceless")) {
        g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "no surfaceless EGL platform");
        return NULL;
    }
    EGLDisplay egl = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (egl == EGL_NO_DISPLAY) {
        g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "eglGetPlatformDisplayEXT failed");
        return NULL;
    }
    return egl;
}
