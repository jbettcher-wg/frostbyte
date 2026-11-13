/*
 * LeopardEGL - EGL 1.5 for Mac OS X 10.5 (FrostByte / WPE WebKit).
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 *
 * Tiers (README section 18), chosen at eglInitialize from LEOPARD_WPE_GL:
 *  - "soft" (default): a complete, honest EGL with no GL. Zero configs, so every context/surface
 *    request fails cleanly and WebKit stays on its CPU (Skia raster + SHM) path.
 *  - "gl21"/"gl33": GLES 2.0 over a CGL OpenGL 2.1 compatibility context (renderer 0x00021a00 on
 *    the RadeonNI driver, else any accelerated renderer). One RGBA8/D24S8 config; contexts are CGL
 *    contexts sharing through CGL share groups; surfaceless contexts and pbuffers render through
 *    FBOs only. The GLES presentation layer is libGLESv2 (gles.c). gl33 currently means the same.
 *  - "gl33" in a WebGL build (LEOPARD_EGL_WEBGL=1, FrostByte 0.4; docs/webgl-plan.md section 3): GLES 3.0
 *    (or 2.0 with LEOPARD_GL33_ES=2) over the RadeonNI driver's per-process modern compatibility context
 *    (RDNGLRequestCompatibilityContext before the first CGL context, RDNGLMakeCurrent after every
 *    CGLSetCurrentContext, GL through RDNGLGetProcAddress). Falls back to gl21 when the driver refuses.
 *    Every GL tier of a WebGL build advertises EGL_LEOPARD_webgl (since 2026-11-12: WebGL 1 on gl21 with any
 *    accelerated renderer, WebGL 1/2 on gl33; whether a page gets WebGL is FrostByte's decision, enable-webgl).
 *    Contexts created with EGL_CONTEXT_CLIENT_LITTLE_ENDIAN_LEOPARD (ANGLE's, for WebGL) take little-endian client
 *    pixel data (GL_UNPACK/PACK_SWAP_BYTES); ANGLE converts their buffer data to host order itself, unless a
 *    driver offers RDNGLSetClientByteOrder (optional fast path, query bit 2; plan 4.4.6).
 * Without LEOPARD_EGL_WEBGL the library is exactly the 0.3.x one.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <OpenGL/OpenGL.h>
#include <dlfcn.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "gles_private.h"

#define EXPORT __attribute__((visibility("default")))

#ifndef LEOPARD_EGL_WEBGL
#define LEOPARD_EGL_WEBGL 0
#endif
/* Private EGL context attribute (and eglQueryContext name): the context's client data is little-endian.
 * Query result bits: 1 = pixel data (UNPACK/PACK_SWAP_BYTES), 2 = buffer data (driver mode). */
#define EGL_CONTEXT_CLIENT_LITTLE_ENDIAN_LEOPARD 0x3F20

typedef struct LeopardDisplay {
    int magic;            /* 'LEGL' */
    EGLBoolean initialized;
    EGLenum platform;
} LeopardDisplay;

#define DISPLAY_MAGIC 0x4c45474c
static LeopardDisplay g_default_display = { DISPLAY_MAGIC, EGL_FALSE, 0 };
static LeopardDisplay g_surfaceless_display = { DISPLAY_MAGIC, EGL_FALSE, EGL_PLATFORM_SURFACELESS_MESA };
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

enum { TIER_SOFT, TIER_GL21, TIER_GL33 };
#define GL_TIER() (g_tier >= TIER_GL21)
static int g_tier = -1;                         /* decided once, at the first eglInitialize */
static CGLPixelFormatObj g_pf;
static char g_vendor[160] = "FrostByte LeopardEGL (soft)";

#define CONFIG_MAGIC 0x4c43464eu   /* 'LCFN' */
#define CONTEXT_MAGIC 0x4c43544bu  /* 'LCTK' */
#define SURFACE_MAGIC 0x4c535246u  /* 'LSRF' */
typedef struct { unsigned magic; EGLint id; } LeopardConfig;
typedef struct LeopardContext {
    unsigned magic; CGLContextObj cgl; pthread_t bound; int is_bound; struct LeopardContext *group;
    int prepared;      /* the one-time ES rules have been applied (first make-current) */
    int client_le;     /* EGL_CONTEXT_CLIENT_LITTLE_ENDIAN_LEOPARD bits granted (1 pixels, 2 buffers) */
} LeopardContext;
typedef struct { unsigned magic; EGLint width, height; } LeopardSurface;
static LeopardConfig g_config = { CONFIG_MAGIC, 1 };

/* per-thread state */
typedef struct {
    EGLint error;
    EGLenum api;
    EGLDisplay display;
    EGLContext context;
    EGLSurface draw, read;
} ThreadState;
static pthread_key_t g_tls_key;
static pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;
static void make_key(void) { pthread_key_create(&g_tls_key, free); }
static ThreadState *ts(void)
{
    pthread_once(&g_tls_once, make_key);
    ThreadState *t = pthread_getspecific(g_tls_key);
    if (!t) {
        t = calloc(1, sizeof *t);
        t->error = EGL_SUCCESS;
        t->api = EGL_OPENGL_ES_API;
        pthread_setspecific(g_tls_key, t);
    }
    return t;
}
#define FAIL(err, ret) do { ts()->error = (err); return (ret); } while (0)
#define OK(ret) do { ts()->error = EGL_SUCCESS; return (ret); } while (0)

static LeopardDisplay *display_of(EGLDisplay dpy)
{
    LeopardDisplay *d = (LeopardDisplay *)dpy;
    if (d != &g_default_display && d != &g_surfaceless_display) return NULL;
    return d;
}
/* Validates dpy; on failure sets the error and evaluates to NULL. */
static LeopardDisplay *checked_display(EGLDisplay dpy, int needInit)
{
    LeopardDisplay *d = display_of(dpy);
    if (!d) { ts()->error = EGL_BAD_DISPLAY; return NULL; }
    if (needInit && !d->initialized) { ts()->error = EGL_NOT_INITIALIZED; return NULL; }
    return d;
}

static const char k_client_extensions[] =
    "EGL_EXT_client_extensions EGL_EXT_platform_base EGL_MESA_platform_surfaceless";
static const char k_display_extensions_zero_copy[] =
    "EGL_KHR_surfaceless_context EGL_KHR_no_config_context EGL_KHR_get_all_proc_addresses"
    " EGL_KHR_fence_sync EGL_KHR_wait_sync"
    " EGL_KHR_image_base EGL_KHR_gl_texture_2D_image EGL_MESA_image_dma_buf_export";
static const char k_display_extensions[] =
    "EGL_KHR_surfaceless_context EGL_KHR_no_config_context EGL_KHR_get_all_proc_addresses"
    " EGL_KHR_fence_sync EGL_KHR_wait_sync";

/* ---- LeopardGPU shared buffers (RadeonNI driver) ---- */
#define LEOPARD_FOURCC_ARGB8888 0x34325241u    /* 'AR24': native BE32 0xAARRGGBB */
#define LEOPARD_MODIFIER_INVALID 0x00ffffffffffffffULL
typedef uint32_t (*PFN_SharedBufferVersion)(void *);
typedef int (*PFN_BufferCreate)(void *, uint32_t, uint32_t, uint32_t, uint64_t, uint32_t *);
typedef int (*PFN_BufferBindTexture)(void *, uint32_t, unsigned int);
typedef int (*PFN_BufferExport)(void *, uint32_t, int *, uint32_t *, uint32_t *, uint32_t *, uint64_t *);
static struct {
    PFN_SharedBufferVersion version;
    PFN_BufferCreate create;
    PFN_BufferBindTexture bind;
    PFN_BufferExport export_;
} g_lgpu;
static int g_shared_buffers;   /* set at tier selection: zero-copy frame export available */

static int load_leopard_gpu(void)
{
    g_lgpu.version = (PFN_SharedBufferVersion)dlsym(RTLD_DEFAULT, "LeopardGPU_SharedBufferVersion");
    g_lgpu.create = (PFN_BufferCreate)dlsym(RTLD_DEFAULT, "LeopardGPU_BufferCreate");
    g_lgpu.bind = (PFN_BufferBindTexture)dlsym(RTLD_DEFAULT, "LeopardGPU_BufferBindTexture");
    g_lgpu.export_ = (PFN_BufferExport)dlsym(RTLD_DEFAULT, "LeopardGPU_BufferExport");
    return g_lgpu.version && g_lgpu.create && g_lgpu.bind && g_lgpu.export_;
}

/* ---- the RadeonNI modern-context bridge (gl33, WebGL builds) ---- */
#define RADEONNI_GLD "/System/Library/Extensions/RadeonNIGLDriver.bundle/Contents/MacOS/RadeonNIGLDriver"
static struct {
    int (*request)(int, int);
    int (*make_current)(void *);
    void *(*get_proc)(const char *);
    int (*set_byte_order)(void *, int);   /* RDNGLSetClientByteOrder: not in the driver yet (plan 4.4.5) */
} g_bridge;
static int g_es_major = 2;                  /* the GLES version presented (gl33: 3, or LEOPARD_GL33_ES=2) */
static char g_display_extensions[512];

/* CGLSetCurrentContext, plus the bridge's own make-current in gl33 (RDNGLMakeCurrent after every switch). */
static CGLError set_current(CGLContextObj c)
{
    CGLError e = CGLSetCurrentContext(c);
    if (e == kCGLNoError && g_tier == TIER_GL33 && g_bridge.make_current)
        g_bridge.make_current(c);
    return e;
}

/* ---- tier selection ---- */
#define RADEONNI_COMPAT_RENDERER 0x00021a00

static CGLPixelFormatObj pixel_format_for(GLint renderer)
{
    CGLPixelFormatAttribute with_id[] = {
        kCGLPFARendererID, (CGLPixelFormatAttribute)renderer, kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0
    };
    CGLPixelFormatAttribute any_accelerated[] = { kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0 };
    CGLPixelFormatObj pf = NULL;
    GLint n = 0;
    if (CGLChoosePixelFormat(renderer ? with_id : any_accelerated, &pf, &n) != kCGLNoError)
        return NULL;
    return pf;
}

static void choose_tier(void)   /* under g_lock */
{
    g_tier = TIER_SOFT;
    const char *want = getenv("LEOPARD_WPE_GL");
    if (!want || (strcmp(want, "gl21") && strcmp(want, "gl33")))
        return;
#if LEOPARD_EGL_WEBGL
    /* gl33: the modern bridge must be requested before this process makes any CGL context. A renderer
     * query loads and initialises the driver without making one (a bare dlopen leaves it uninitialised). */
    int modern = 0;
    if (!strcmp(want, "gl33")) {
        CGLRendererInfoObj info = NULL;
        GLint count = 0;
        if (CGLQueryRendererInfo(0xffffffff, &info, &count) == kCGLNoError)
            CGLDestroyRendererInfo(info);
        void *gld = dlopen(RADEONNI_GLD, RTLD_LAZY | RTLD_LOCAL);
        if (gld) {
            g_bridge.request = (int (*)(int, int))dlsym(gld, "RDNGLRequestCompatibilityContext");
            g_bridge.make_current = (int (*)(void *))dlsym(gld, "RDNGLMakeCurrent");
            g_bridge.get_proc = (void *(*)(const char *))dlsym(gld, "RDNGLGetProcAddress");
            g_bridge.set_byte_order = (int (*)(void *, int))dlsym(gld, "RDNGLSetClientByteOrder");
        }
        setenv("RDN_GLTHREAD", "0", 0);        /* no glthread under WebKit's multi-threaded contexts (plan 2.3) */
        modern = g_bridge.request && g_bridge.make_current && g_bridge.get_proc && g_bridge.request(4, 6);
        if (!modern)
            fprintf(stderr, "LeopardEGL: gl33: the driver refused a modern context (%s); using gl21\n",
                    !gld ? "no RadeonNI GL driver" : !g_bridge.request ? "no bridge in the driver" : "RDNGLRequestCompatibilityContext");
        const char *es = getenv("LEOPARD_GL33_ES");
        g_es_major = modern && !(es && !strcmp(es, "2")) ? 3 : 2;
    }
#endif
    const char *forced = getenv("LEOPARD_EGL_RENDERER");          /* hex renderer ID, for testing */
    GLint renderer = forced ? (GLint)strtol(forced, NULL, 16) : RADEONNI_COMPAT_RENDERER;
    CGLPixelFormatObj pf = pixel_format_for(renderer);
    if (!pf && !forced)
        pf = pixel_format_for(0);
    if (!pf)
        return;
    /* Prove it: a context must come up and report a renderer. */
    CGLContextObj probe = NULL, previous = CGLGetCurrentContext();
    if (CGLCreateContext(pf, NULL, &probe) != kCGLNoError || !probe) {
        CGLDestroyPixelFormat(pf);
        return;
    }
#if LEOPARD_EGL_WEBGL
    if (modern) {
        g_tier = TIER_GL33;                     /* set_current now pairs RDNGLMakeCurrent */
        lgl_set_provider(g_bridge.get_proc, g_es_major);
    }
#endif
    set_current(probe);
    typedef const unsigned char *(*GetString)(unsigned);
    GetString get = (GetString)lgl_resolve("glGetString");
    const char *r = get ? (const char *)get(0x1F01 /* GL_RENDERER */) : NULL;
    const char *v = get ? (const char *)get(0x1F02 /* GL_VERSION */) : NULL;
    /* Zero-copy frames: the driver's shared buffers, unless LEOPARD_WPE_ZEROCOPY=0. */
    const char *zero_copy = getenv("LEOPARD_WPE_ZEROCOPY");
    g_shared_buffers = (!zero_copy || strcmp(zero_copy, "0")) && load_leopard_gpu() && g_lgpu.version(probe) > 0;
    snprintf(g_vendor, sizeof g_vendor, "FrostByte LeopardEGL (%s%s: %s, %s)", g_tier == TIER_GL33 ? "gl33" : "gl21",
             g_shared_buffers ? " zero-copy" : "", r ? r : "?", v ? v : "?");
    set_current(previous);
    CGLDestroyContext(probe);
    g_pf = pf;
    if (g_tier != TIER_GL33)
        g_tier = TIER_GL21;
    snprintf(g_display_extensions, sizeof g_display_extensions, "%s%s%s",
             g_shared_buffers ? k_display_extensions_zero_copy : k_display_extensions,
             LEOPARD_EGL_WEBGL ? " EGL_LEOPARD_client_little_endian" : "",
             LEOPARD_EGL_WEBGL ? " EGL_LEOPARD_webgl" : "");
}

/* ---- display ---- */
EXPORT EGLDisplay EGLAPIENTRY eglGetDisplay(EGLNativeDisplayType native)
{
    (void)native;
    OK((EGLDisplay)&g_default_display);
}

EXPORT EGLDisplay EGLAPIENTRY eglGetPlatformDisplay(EGLenum platform, void *native, const EGLAttrib *attribs)
{
    (void)native; (void)attribs;
    if (platform == EGL_PLATFORM_SURFACELESS_MESA) OK((EGLDisplay)&g_surfaceless_display);
    FAIL(EGL_BAD_PARAMETER, EGL_NO_DISPLAY);   /* no GBM, Wayland, X11, Device platforms on Leopard */
}

EXPORT EGLDisplay EGLAPIENTRY eglGetPlatformDisplayEXT(EGLenum platform, void *native, const EGLint *attribs)
{
    (void)attribs;
    return eglGetPlatformDisplay(platform, native, NULL);
}

EXPORT EGLBoolean EGLAPIENTRY eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor)
{
    LeopardDisplay *d = checked_display(dpy, 0);
    if (!d) return EGL_FALSE;
    pthread_mutex_lock(&g_lock);
    if (g_tier < 0)
        choose_tier();
    d->initialized = EGL_TRUE;
    pthread_mutex_unlock(&g_lock);
    if (major) *major = 1;
    if (minor) *minor = 5;
    OK(EGL_TRUE);
}

EXPORT EGLBoolean EGLAPIENTRY eglTerminate(EGLDisplay dpy)
{
    LeopardDisplay *d = checked_display(dpy, 0);
    if (!d) return EGL_FALSE;
    pthread_mutex_lock(&g_lock);
    d->initialized = EGL_FALSE;
    pthread_mutex_unlock(&g_lock);
    OK(EGL_TRUE);
}

EXPORT const char *EGLAPIENTRY eglQueryString(EGLDisplay dpy, EGLint name)
{
    if (dpy == EGL_NO_DISPLAY) {
        if (name == EGL_EXTENSIONS) OK(k_client_extensions);
        if (name == EGL_VERSION) OK("1.5 LeopardEGL");
        FAIL(EGL_BAD_DISPLAY, NULL);
    }
    if (!checked_display(dpy, 1)) return NULL;
    switch (name) {
    case EGL_VENDOR: OK(g_vendor);
    case EGL_VERSION: OK("1.5 LeopardEGL");
    case EGL_EXTENSIONS:
        if (g_display_extensions[0]) OK(g_display_extensions);
        OK(g_shared_buffers ? k_display_extensions_zero_copy : k_display_extensions);
    case EGL_CLIENT_APIS: OK(GL_TIER() ? "OpenGL_ES" : "");
    }
    FAIL(EGL_BAD_PARAMETER, NULL);
}

/* ---- configs: none in the soft tier, one in gl21 ---- */
static LeopardConfig *config_of(EGLConfig c)
{
    return (c == (EGLConfig)&g_config && GL_TIER()) ? &g_config : NULL;
}

static EGLBoolean config_attrib(EGLint attribute, EGLint *value)
{
    switch (attribute) {
    case EGL_CONFIG_ID: *value = g_config.id; return EGL_TRUE;
    case EGL_RED_SIZE: case EGL_GREEN_SIZE: case EGL_BLUE_SIZE: case EGL_ALPHA_SIZE: *value = 8; return EGL_TRUE;
    case EGL_BUFFER_SIZE: *value = 32; return EGL_TRUE;
    case EGL_DEPTH_SIZE: *value = 24; return EGL_TRUE;
    case EGL_STENCIL_SIZE: *value = 8; return EGL_TRUE;
    case EGL_LUMINANCE_SIZE: case EGL_ALPHA_MASK_SIZE: case EGL_SAMPLES: case EGL_SAMPLE_BUFFERS:
    case EGL_LEVEL: case EGL_NATIVE_VISUAL_ID: case EGL_NATIVE_VISUAL_TYPE: case EGL_MIN_SWAP_INTERVAL:
    case EGL_TRANSPARENT_RED_VALUE: case EGL_TRANSPARENT_GREEN_VALUE: case EGL_TRANSPARENT_BLUE_VALUE:
        *value = 0; return EGL_TRUE;
    case EGL_MAX_SWAP_INTERVAL: *value = 1; return EGL_TRUE;
    case EGL_COLOR_BUFFER_TYPE: *value = EGL_RGB_BUFFER; return EGL_TRUE;
    case EGL_CONFIG_CAVEAT: *value = EGL_NONE; return EGL_TRUE;
    case EGL_TRANSPARENT_TYPE: *value = EGL_NONE; return EGL_TRUE;
    case EGL_NATIVE_RENDERABLE: case EGL_BIND_TO_TEXTURE_RGB: case EGL_BIND_TO_TEXTURE_RGBA: *value = EGL_FALSE; return EGL_TRUE;
    case EGL_RENDERABLE_TYPE: case EGL_CONFORMANT:
        *value = EGL_OPENGL_ES2_BIT | (g_es_major >= 3 ? 0x40 /* EGL_OPENGL_ES3_BIT */ : 0); return EGL_TRUE;
    case EGL_SURFACE_TYPE: *value = EGL_PBUFFER_BIT | EGL_WINDOW_BIT; return EGL_TRUE;
    case EGL_MAX_PBUFFER_WIDTH: case EGL_MAX_PBUFFER_HEIGHT: *value = 16384; return EGL_TRUE;
    case EGL_MAX_PBUFFER_PIXELS: *value = 16384 * 16384; return EGL_TRUE;
    }
    return EGL_FALSE;
}

/* Does our one config satisfy the requested attributes? (EGL 1.5 3.4.1 selection rules, the
 * subset that can disqualify a single RGBA8/D24S8 GLES2 pbuffer+window config.) */
static int config_matches(const EGLint *attribs)
{
    for (const EGLint *a = attribs; a && a[0] != EGL_NONE; a += 2) {
        EGLint want = a[1], have = 0;
        if (want == EGL_DONT_CARE)
            continue;
        switch (a[0]) {
        case EGL_RENDERABLE_TYPE: case EGL_CONFORMANT: case EGL_SURFACE_TYPE:   /* mask: all bits needed */
            config_attrib(a[0], &have);
            if ((want & have) != want) return 0;
            break;
        case EGL_CONFIG_ID:
            if (want != g_config.id) return 0;
            break;
        case EGL_COLOR_BUFFER_TYPE: case EGL_CONFIG_CAVEAT: case EGL_TRANSPARENT_TYPE:
        case EGL_NATIVE_RENDERABLE: case EGL_NATIVE_VISUAL_TYPE: case EGL_LEVEL:
            config_attrib(a[0], &have);
            if (want != have) return 0;
            break;
        case EGL_BIND_TO_TEXTURE_RGB: case EGL_BIND_TO_TEXTURE_RGBA:
            if (want == EGL_TRUE) return 0;
            break;
        case EGL_MATCH_NATIVE_PIXMAP:
            return 0;
        default:                                                                 /* minimum sizes */
            if (config_attrib(a[0], &have) && want > have) return 0;
        }
    }
    return 1;
}

EXPORT EGLBoolean EGLAPIENTRY eglGetConfigs(EGLDisplay dpy, EGLConfig *configs, EGLint size, EGLint *num)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!num) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    *num = 0;
    if (GL_TIER()) {
        if (configs && size > 0)
            configs[0] = (EGLConfig)&g_config;
        *num = (!configs || size > 0) ? 1 : 0;
    }
    OK(EGL_TRUE);
}

EXPORT EGLBoolean EGLAPIENTRY eglChooseConfig(EGLDisplay dpy, const EGLint *attribs, EGLConfig *configs, EGLint size, EGLint *num)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!num) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    *num = 0;
    if (GL_TIER() && config_matches(attribs)) {
        if (configs && size > 0)
            configs[0] = (EGLConfig)&g_config;
        *num = (!configs || size > 0) ? 1 : 0;
    }
    OK(EGL_TRUE);
}

EXPORT EGLBoolean EGLAPIENTRY eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config, EGLint attribute, EGLint *value)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!config_of(config)) FAIL(EGL_BAD_CONFIG, EGL_FALSE);
    if (!value || !config_attrib(attribute, value)) FAIL(EGL_BAD_ATTRIBUTE, EGL_FALSE);
    OK(EGL_TRUE);
}

/* ---- surfaces: pbuffers only (rendering goes to FBOs; there is no default framebuffer) ---- */
static LeopardSurface *surface_of(EGLSurface s)
{
    LeopardSurface *x = (LeopardSurface *)s;
    return (x && x->magic == SURFACE_MAGIC) ? x : NULL;
}

EXPORT EGLSurface EGLAPIENTRY eglCreateWindowSurface(EGLDisplay dpy, EGLConfig c, EGLNativeWindowType w, const EGLint *a)
{
    (void)w; (void)a;
    if (!checked_display(dpy, 1)) return EGL_NO_SURFACE;
    if (!config_of(c)) FAIL(EGL_BAD_CONFIG, EGL_NO_SURFACE);
    FAIL(EGL_BAD_NATIVE_WINDOW, EGL_NO_SURFACE);   /* windows belong to the Cocoa backend */
}
EXPORT EGLSurface EGLAPIENTRY eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig c, void *w, const EGLAttrib *a)
{
    (void)a;
    return eglCreateWindowSurface(dpy, c, (EGLNativeWindowType)w, NULL);
}
EXPORT EGLSurface EGLAPIENTRY eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig c, const EGLint *a)
{
    if (!checked_display(dpy, 1)) return EGL_NO_SURFACE;
    if (!config_of(c)) FAIL(EGL_BAD_CONFIG, EGL_NO_SURFACE);
    LeopardSurface *s = calloc(1, sizeof *s);
    s->magic = SURFACE_MAGIC;
    for (; a && a[0] != EGL_NONE; a += 2) {
        if (a[0] == EGL_WIDTH) s->width = a[1];
        else if (a[0] == EGL_HEIGHT) s->height = a[1];
    }
    OK((EGLSurface)s);
}
EXPORT EGLSurface EGLAPIENTRY eglCreatePixmapSurface(EGLDisplay dpy, EGLConfig c, EGLNativePixmapType p, const EGLint *a)
{
    (void)p; (void)a;
    if (!checked_display(dpy, 1)) return EGL_NO_SURFACE;
    if (!config_of(c)) FAIL(EGL_BAD_CONFIG, EGL_NO_SURFACE);
    FAIL(EGL_BAD_NATIVE_PIXMAP, EGL_NO_SURFACE);
}
EXPORT EGLBoolean EGLAPIENTRY eglDestroySurface(EGLDisplay dpy, EGLSurface s)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardSurface *x = surface_of(s);
    if (!x) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    x->magic = 0;
    free(x);
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglQuerySurface(EGLDisplay dpy, EGLSurface s, EGLint a, EGLint *v)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardSurface *x = surface_of(s);
    if (!x) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    switch (a) {
    case EGL_WIDTH: *v = x->width; break;
    case EGL_HEIGHT: *v = x->height; break;
    case EGL_CONFIG_ID: *v = g_config.id; break;
    case EGL_RENDER_BUFFER: *v = EGL_BACK_BUFFER; break;
    case EGL_SWAP_BEHAVIOR: *v = EGL_BUFFER_DESTROYED; break;
    case EGL_TEXTURE_FORMAT: case EGL_TEXTURE_TARGET: *v = EGL_NO_TEXTURE; break;
    case EGL_LARGEST_PBUFFER: case EGL_MIPMAP_TEXTURE: case EGL_MIPMAP_LEVEL: *v = 0; break;
    default: FAIL(EGL_BAD_ATTRIBUTE, EGL_FALSE);
    }
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglSurfaceAttrib(EGLDisplay dpy, EGLSurface s, EGLint a, EGLint v)
{
    (void)a; (void)v;
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!surface_of(s)) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglSwapBuffers(EGLDisplay dpy, EGLSurface s)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!surface_of(s)) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    CGLContextObj cgl = CGLGetCurrentContext();
    if (cgl)
        CGLFlushDrawable(cgl);   /* no drawable: just a flush */
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglSwapInterval(EGLDisplay dpy, EGLint interval)
{
    (void)interval;
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (ts()->context == EGL_NO_CONTEXT) FAIL(EGL_BAD_CONTEXT, EGL_FALSE);
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglBindTexImage(EGLDisplay dpy, EGLSurface s, EGLint b)
{
    (void)b;
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!surface_of(s)) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    FAIL(EGL_BAD_MATCH, EGL_FALSE);
}
EXPORT EGLBoolean EGLAPIENTRY eglReleaseTexImage(EGLDisplay dpy, EGLSurface s, EGLint b)
{
    (void)b;
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!surface_of(s)) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    FAIL(EGL_BAD_MATCH, EGL_FALSE);
}
EXPORT EGLBoolean EGLAPIENTRY eglCopyBuffers(EGLDisplay dpy, EGLSurface s, EGLNativePixmapType t)
{
    (void)t;
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!surface_of(s)) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    FAIL(EGL_BAD_NATIVE_PIXMAP, EGL_FALSE);
}

/* ---- contexts: CGL contexts on the chosen pixel format ---- */
static LeopardContext *context_of(EGLContext c)
{
    LeopardContext *x = (LeopardContext *)c;
    return (x && x->magic == CONTEXT_MAGIC) ? x : NULL;
}

EXPORT EGLBoolean EGLAPIENTRY eglBindAPI(EGLenum api)
{
    if (api != EGL_OPENGL_ES_API && api != EGL_OPENGL_API) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    ts()->api = api;
    OK(EGL_TRUE);
}
EXPORT EGLenum EGLAPIENTRY eglQueryAPI(void) { return ts()->api; }

EXPORT EGLContext EGLAPIENTRY eglCreateContext(EGLDisplay dpy, EGLConfig c, EGLContext share, const EGLint *a)
{
    if (!checked_display(dpy, 1)) return EGL_NO_CONTEXT;
    if (!GL_TIER()) FAIL(EGL_BAD_MATCH, EGL_NO_CONTEXT);
    if (c != EGL_NO_CONFIG_KHR && !config_of(c)) FAIL(EGL_BAD_CONFIG, EGL_NO_CONTEXT);
    if (ts()->api != EGL_OPENGL_ES_API) FAIL(EGL_BAD_MATCH, EGL_NO_CONTEXT);   /* GLES only */
    LeopardContext *shared = NULL;
    if (share != EGL_NO_CONTEXT && !(shared = context_of(share))) FAIL(EGL_BAD_CONTEXT, EGL_NO_CONTEXT);
    EGLint major = 1, minor = 0, client_le = 0;
    for (; a && a[0] != EGL_NONE; a += 2) {
        switch (a[0]) {
        case EGL_CONTEXT_MAJOR_VERSION: major = a[1]; break;     /* == EGL_CONTEXT_CLIENT_VERSION */
        case EGL_CONTEXT_MINOR_VERSION: minor = a[1]; break;
#if LEOPARD_EGL_WEBGL
        case EGL_CONTEXT_CLIENT_LITTLE_ENDIAN_LEOPARD: client_le = a[1] != EGL_FALSE; break;
#endif
        case EGL_CONTEXT_OPENGL_DEBUG: case EGL_CONTEXT_FLAGS_KHR: case EGL_CONTEXT_OPENGL_ROBUST_ACCESS:
        case EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY: break;   /* accepted, not honoured */
        default: FAIL(EGL_BAD_ATTRIBUTE, EGL_NO_CONTEXT);
        }
    }
    /* What we present: GLES 2.0, or 3.0 on gl33. 3.1/3.2 are refused so ANGLE settles on 3.0 (plan 3.2). */
    if (major > g_es_major || (major == g_es_major && minor > 0)) FAIL(EGL_BAD_MATCH, EGL_NO_CONTEXT);
    CGLContextObj cgl = NULL;
    if (CGLCreateContext(g_pf, shared ? shared->cgl : NULL, &cgl) != kCGLNoError || !cgl)
        FAIL(EGL_BAD_ALLOC, EGL_NO_CONTEXT);
    LeopardContext *x = calloc(1, sizeof *x);
    x->magic = CONTEXT_MAGIC;
    x->cgl = cgl;
    x->group = shared ? shared->group : x;   /* CGLGetShareGroup is 10.6+: track the share group ourselves */
    if (client_le) {
        x->client_le = 1;                     /* pixels: GL_UNPACK/PACK_SWAP_BYTES at first make-current */
        if (g_tier == TIER_GL33 && g_bridge.set_byte_order && g_bridge.set_byte_order(cgl, 1))
            x->client_le |= 2;                /* buffers: the driver's per-context mode (plan 4.4.5) */
    }
    OK((EGLContext)x);
}

EXPORT EGLBoolean EGLAPIENTRY eglDestroyContext(EGLDisplay dpy, EGLContext ctx)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardContext *x = context_of(ctx);
    if (!x) FAIL(EGL_BAD_CONTEXT, EGL_FALSE);
    ThreadState *t = ts();
    if (t->context == ctx) {
        x->is_bound = 0;
        set_current(NULL);
        t->context = EGL_NO_CONTEXT;
        t->draw = t->read = EGL_NO_SURFACE;
        t->display = EGL_NO_DISPLAY;
    }
    CGLDestroyContext(x->cgl);
    x->magic = 0;
    free(x);
    OK(EGL_TRUE);
}

EXPORT EGLBoolean EGLAPIENTRY eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx)
{
    if (!checked_display(dpy, 0)) return EGL_FALSE;
    ThreadState *t = ts();
    if (ctx == EGL_NO_CONTEXT) {
        if (draw != EGL_NO_SURFACE || read != EGL_NO_SURFACE) FAIL(EGL_BAD_MATCH, EGL_FALSE);
        if (t->context != EGL_NO_CONTEXT) {
            pthread_mutex_lock(&g_lock);
            LeopardContext *old = context_of(t->context);
            if (old) old->is_bound = 0;
            pthread_mutex_unlock(&g_lock);
            set_current(NULL);
            lgl_set_current_group(NULL);
        }
        t->context = EGL_NO_CONTEXT;
        t->draw = t->read = EGL_NO_SURFACE;
        t->display = EGL_NO_DISPLAY;
        OK(EGL_TRUE);
    }
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardContext *x = context_of(ctx);
    if (!x) FAIL(EGL_BAD_CONTEXT, EGL_FALSE);
    if ((draw == EGL_NO_SURFACE) != (read == EGL_NO_SURFACE)) FAIL(EGL_BAD_MATCH, EGL_FALSE);   /* surfaceless: both */
    if (draw != EGL_NO_SURFACE && (!surface_of(draw) || !surface_of(read))) FAIL(EGL_BAD_SURFACE, EGL_FALSE);
    /* EGL 1.5 3.7.3: a context may be current to one thread only. CGL would let two threads share
     * it and corrupt the driver's command stream, so refuse like EGL must. */
    pthread_mutex_lock(&g_lock);
    if (x->is_bound && !pthread_equal(x->bound, pthread_self())) {
        pthread_mutex_unlock(&g_lock);
        fprintf(stderr, "LeopardEGL: eglMakeCurrent: context %p is current on another thread (EGL_BAD_ACCESS)\n", (void *)x);
        FAIL(EGL_BAD_ACCESS, EGL_FALSE);
    }
    LeopardContext *old = context_of(t->context);
    if (old && old != x) old->is_bound = 0;
    x->bound = pthread_self();
    x->is_bound = 1;
    pthread_mutex_unlock(&g_lock);
    if (set_current(x->cgl) != kCGLNoError) FAIL(EGL_BAD_ACCESS, EGL_FALSE);
    lgl_set_current_group(x->group);
#if LEOPARD_EGL_WEBGL
    lgl_set_current_client_le(x->client_le);
    if (!x->prepared) {                       /* GLES rules on a desktop context, once (plan 3.3) */
        x->prepared = 1;
        lgl_prepare_context(g_tier == TIER_GL33, x->client_le);
    }
#endif
    t->context = ctx;
    t->draw = draw;
    t->read = read;
    t->display = dpy;
    OK(EGL_TRUE);
}

EXPORT EGLBoolean EGLAPIENTRY eglQueryContext(EGLDisplay dpy, EGLContext ctx, EGLint a, EGLint *v)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    if (!context_of(ctx)) FAIL(EGL_BAD_CONTEXT, EGL_FALSE);
    switch (a) {
    case EGL_CONFIG_ID: *v = g_config.id; break;
    case EGL_CONTEXT_CLIENT_TYPE: *v = EGL_OPENGL_ES_API; break;
    case EGL_CONTEXT_CLIENT_VERSION: *v = g_es_major; break;
#if LEOPARD_EGL_WEBGL
    case EGL_CONTEXT_CLIENT_LITTLE_ENDIAN_LEOPARD: *v = context_of(ctx)->client_le; break;
#endif
    case EGL_RENDER_BUFFER: *v = ts()->draw != EGL_NO_SURFACE ? EGL_BACK_BUFFER : EGL_NONE; break;
    default: FAIL(EGL_BAD_ATTRIBUTE, EGL_FALSE);
    }
    OK(EGL_TRUE);
}
EXPORT EGLContext EGLAPIENTRY eglGetCurrentContext(void) { return ts()->context; }
EXPORT EGLSurface EGLAPIENTRY eglGetCurrentSurface(EGLint which)
{
    ThreadState *t = ts();
    if (which == EGL_DRAW) return t->draw;
    if (which == EGL_READ) return t->read;
    FAIL(EGL_BAD_PARAMETER, EGL_NO_SURFACE);
}
EXPORT EGLDisplay EGLAPIENTRY eglGetCurrentDisplay(void) { return ts()->display; }

/* ---- sync / misc ---- */
static void current_finish(void)
{
    typedef void (*Finish)(void);
    static Finish finish;
    if (ts()->context == EGL_NO_CONTEXT)
        return;
    if (!finish)
        finish = (Finish)lgl_resolve("glFinish");
    if (finish)
        finish();
}
EXPORT EGLBoolean EGLAPIENTRY eglWaitClient(void) { current_finish(); OK(EGL_TRUE); }
EXPORT EGLBoolean EGLAPIENTRY eglWaitGL(void) { current_finish(); OK(EGL_TRUE); }
EXPORT EGLBoolean EGLAPIENTRY eglWaitNative(EGLint engine) { (void)engine; OK(EGL_TRUE); }
EXPORT EGLBoolean EGLAPIENTRY eglReleaseThread(void)
{
    ThreadState *t = ts();
    if (t->context != EGL_NO_CONTEXT) {
        pthread_mutex_lock(&g_lock);
        LeopardContext *old = context_of(t->context);
        if (old) old->is_bound = 0;
        pthread_mutex_unlock(&g_lock);
        set_current(NULL);
    }
    t->context = EGL_NO_CONTEXT;
    t->draw = t->read = EGL_NO_SURFACE;
    t->display = EGL_NO_DISPLAY;
    t->api = EGL_OPENGL_ES_API;
    OK(EGL_TRUE);
}
EXPORT EGLint EGLAPIENTRY eglGetError(void)
{
    ThreadState *t = ts();
    EGLint e = t->error;
    t->error = EGL_SUCCESS;
    return e;
}

/* ---- images: GL textures re-backed by LeopardGPU shared buffers, exportable as DMA-BUF-style fds ---- */
#define IMAGE_MAGIC 0x4c494d47u  /* 'LIMG' */
typedef struct {
    unsigned magic;
    CGLContextObj cgl;
    uint32_t buffer;
    unsigned int texture;
    int fd;                      /* from the last export query, handed over by the export */
    uint32_t fourcc, offset, stride;
    uint64_t modifier;
} LeopardImage;

static LeopardImage *image_of(EGLImage i)
{
    LeopardImage *x = (LeopardImage *)i;
    return (x && x->magic == IMAGE_MAGIC) ? x : NULL;
}

typedef void (*PFN_GetIntegerv)(unsigned, int *);
typedef void (*PFN_BindTexture)(unsigned, unsigned);
typedef void (*PFN_GetTexLevelParameteriv)(unsigned, int, unsigned, int *);
#define GL_TEXTURE_2D_ 0x0DE1
#define GL_TEXTURE_BINDING_2D_ 0x8069
#define GL_TEXTURE_WIDTH_ 0x1000
#define GL_TEXTURE_HEIGHT_ 0x1001

static EGLImage create_texture_image(EGLDisplay dpy, EGLContext ctx, EGLenum target, EGLClientBuffer buffer)
{
    if (!checked_display(dpy, 1)) return EGL_NO_IMAGE;
    if (!g_shared_buffers) FAIL(EGL_BAD_PARAMETER, EGL_NO_IMAGE);
    if (target != EGL_GL_TEXTURE_2D) FAIL(EGL_BAD_PARAMETER, EGL_NO_IMAGE);
    LeopardContext *c = context_of(ctx);
    if (!c) FAIL(EGL_BAD_CONTEXT, EGL_NO_IMAGE);
    unsigned int texture = (unsigned int)(uintptr_t)buffer;
    if (!texture) FAIL(EGL_BAD_PARAMETER, EGL_NO_IMAGE);

    CGLContextObj previous = CGLGetCurrentContext();
    if (previous != c->cgl) set_current(c->cgl);
    static PFN_GetIntegerv get_integer;
    static PFN_BindTexture bind_texture;
    static PFN_GetTexLevelParameteriv get_level;
    if (!get_integer) get_integer = (PFN_GetIntegerv)lgl_resolve("glGetIntegerv");
    if (!bind_texture) bind_texture = (PFN_BindTexture)lgl_resolve("glBindTexture");
    if (!get_level) get_level = (PFN_GetTexLevelParameteriv)lgl_resolve("glGetTexLevelParameteriv");
    int bound = 0, width = 0, height = 0;
    get_integer(GL_TEXTURE_BINDING_2D_, &bound);
    bind_texture(GL_TEXTURE_2D_, texture);
    get_level(GL_TEXTURE_2D_, 0, GL_TEXTURE_WIDTH_, &width);
    get_level(GL_TEXTURE_2D_, 0, GL_TEXTURE_HEIGHT_, &height);

    /* Re-back the texture with a shared buffer (once per texture), keeping its name. */
    void *group = c->group;
    uint32_t id = lgl_lookup_texture_buffer(group, texture);
    int ok = id != 0;
    if (!id && width > 0 && height > 0 &&
        g_lgpu.create(c->cgl, (uint32_t)width, (uint32_t)height, LEOPARD_FOURCC_ARGB8888, LEOPARD_MODIFIER_INVALID, &id) == 0) {
        ok = g_lgpu.bind(c->cgl, id, texture) == 0;
        if (ok)
            lgl_register_texture_buffer(group, texture, id);
    }
    bind_texture(GL_TEXTURE_2D_, (unsigned)bound);
    if (previous != c->cgl) set_current(previous);
    if (!ok) FAIL(EGL_BAD_ALLOC, EGL_NO_IMAGE);

    LeopardImage *x = calloc(1, sizeof *x);
    x->magic = IMAGE_MAGIC;
    x->cgl = c->cgl;
    x->buffer = id;
    x->texture = texture;
    x->fd = -1;
    OK((EGLImage)x);
}

EXPORT EGLImage EGLAPIENTRY eglCreateImage(EGLDisplay dpy, EGLContext ctx, EGLenum target, EGLClientBuffer b, const EGLAttrib *a)
{
    (void)a;
    return create_texture_image(dpy, ctx, target, b);
}
EXPORT EGLImageKHR EGLAPIENTRY eglCreateImageKHR(EGLDisplay dpy, EGLContext ctx, EGLenum target, EGLClientBuffer b, const EGLint *a)
{
    (void)a;
    return create_texture_image(dpy, ctx, target, b);
}

/* The buffer stays with the texture (released by glDeleteTextures in libGLESv2). */
EXPORT EGLBoolean EGLAPIENTRY eglDestroyImage(EGLDisplay dpy, EGLImage img)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardImage *x = image_of(img);
    if (!x) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    if (x->fd >= 0) close(x->fd);   /* queried but never exported */
    x->magic = 0;
    free(x);
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglDestroyImageKHR(EGLDisplay dpy, EGLImageKHR img) { return eglDestroyImage(dpy, img); }

static int export_image(LeopardImage *x)
{
    if (x->fd >= 0)
        return 1;
    int fd = -1;
    if (g_lgpu.export_(x->cgl, x->buffer, &fd, &x->fourcc, &x->offset, &x->stride, &x->modifier) != 0 || fd < 0)
        return 0;
    x->fd = fd;
    return 1;
}

EXPORT EGLBoolean EGLAPIENTRY eglExportDMABUFImageQueryMESA(EGLDisplay dpy, EGLImageKHR img, int *fourcc, int *planes, EGLuint64KHR *modifiers)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardImage *x = image_of(img);
    if (!x) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    if (!export_image(x)) FAIL(EGL_BAD_ALLOC, EGL_FALSE);
    if (fourcc) *fourcc = (int)x->fourcc;
    if (planes) *planes = 1;
    if (modifiers) *modifiers = x->modifier;
    OK(EGL_TRUE);
}

EXPORT EGLBoolean EGLAPIENTRY eglExportDMABUFImageMESA(EGLDisplay dpy, EGLImageKHR img, int *fds, EGLint *strides, EGLint *offsets)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardImage *x = image_of(img);
    if (!x) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    if (!export_image(x)) FAIL(EGL_BAD_ALLOC, EGL_FALSE);
    if (fds) { fds[0] = x->fd; x->fd = -1; }   /* ownership passes to the caller */
    if (strides) strides[0] = (EGLint)x->stride;
    if (offsets) offsets[0] = (EGLint)x->offset;
    OK(EGL_TRUE);
}

/* ---- fence sync: GL sync objects (ARB_sync) shared across the CGL share group, or glFinish ---- */
#define SYNC_MAGIC 0x4c53594eu  /* 'LSYN' */
typedef struct { unsigned magic; void *gl; } LeopardSync;

typedef void *(*PFNFenceSync)(unsigned, unsigned);
typedef unsigned (*PFNClientWaitSync)(void *, unsigned, unsigned long long);
typedef void (*PFNWaitSync)(void *, unsigned, unsigned long long);
typedef void (*PFNDeleteSync)(void *);
typedef void (*PFNGetSynciv)(void *, unsigned, int, int *, int *);
typedef void (*PFNVoid)(void);
#define GL_SYNC_GPU_COMMANDS_COMPLETE_ 0x9117
#define GL_SYNC_FLUSH_COMMANDS_BIT_ 0x1
#define GL_ALREADY_SIGNALED_ 0x911A
#define GL_TIMEOUT_EXPIRED_ 0x911B
#define GL_CONDITION_SATISFIED_ 0x911C
#define GL_SYNC_STATUS_ 0x9114
#define GL_SIGNALED_ 0x9119
#define GL_TIMEOUT_IGNORED_ 0xFFFFFFFFFFFFFFFFull

static LeopardSync *sync_of(EGLSync s)
{
    LeopardSync *x = (LeopardSync *)s;
    return (x && x->magic == SYNC_MAGIC) ? x : NULL;
}

static EGLSync create_fence(EGLDisplay dpy, EGLenum type)
{
    if (!checked_display(dpy, 1)) return EGL_NO_SYNC;
    if (type != EGL_SYNC_FENCE) FAIL(EGL_BAD_ATTRIBUTE, EGL_NO_SYNC);
    if (ts()->context == EGL_NO_CONTEXT) FAIL(EGL_BAD_MATCH, EGL_NO_SYNC);
    static PFNFenceSync fence;
    static PFNVoid flush, finish;
    if (!fence) fence = (PFNFenceSync)lgl_resolve("glFenceSync");
    if (!flush) flush = (PFNVoid)lgl_resolve("glFlush");
    if (!finish) finish = (PFNVoid)lgl_resolve("glFinish");
    LeopardSync *x = calloc(1, sizeof *x);
    x->magic = SYNC_MAGIC;
    if (fence && (x->gl = fence(GL_SYNC_GPU_COMMANDS_COMPLETE_, 0))) {
        if (flush) flush();   /* so waits in other contexts make progress */
    } else if (finish)
        finish();             /* no sync objects: complete now, the fence starts signalled */
    OK((EGLSync)x);
}

EXPORT EGLSync EGLAPIENTRY eglCreateSync(EGLDisplay dpy, EGLenum type, const EGLAttrib *a)
{
    if (a && a[0] != EGL_NONE) { (void)checked_display(dpy, 1); FAIL(EGL_BAD_ATTRIBUTE, EGL_NO_SYNC); }
    return create_fence(dpy, type);
}
EXPORT EGLSyncKHR EGLAPIENTRY eglCreateSyncKHR(EGLDisplay dpy, EGLenum type, const EGLint *a)
{
    if (a && a[0] != EGL_NONE) { (void)checked_display(dpy, 1); FAIL(EGL_BAD_ATTRIBUTE, EGL_NO_SYNC); }
    return create_fence(dpy, type);
}

EXPORT EGLBoolean EGLAPIENTRY eglDestroySync(EGLDisplay dpy, EGLSync s)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardSync *x = sync_of(s);
    if (!x) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    static PFNDeleteSync del;
    if (!del) del = (PFNDeleteSync)lgl_resolve("glDeleteSync");
    if (x->gl && del && CGLGetCurrentContext())
        del(x->gl);           /* sync objects belong to the share group; any current context will do */
    x->magic = 0;
    free(x);
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglDestroySyncKHR(EGLDisplay dpy, EGLSyncKHR s) { return eglDestroySync(dpy, s); }

EXPORT EGLint EGLAPIENTRY eglClientWaitSync(EGLDisplay dpy, EGLSync s, EGLint flags, EGLTime timeout)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardSync *x = sync_of(s);
    if (!x) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    if (!x->gl || !CGLGetCurrentContext())
        OK(EGL_CONDITION_SATISFIED);   /* finished at creation (or nothing to wait with) */
    static PFNClientWaitSync wait;
    if (!wait) wait = (PFNClientWaitSync)lgl_resolve("glClientWaitSync");
    if (!wait) OK(EGL_CONDITION_SATISFIED);
    unsigned r = wait(x->gl, (flags & EGL_SYNC_FLUSH_COMMANDS_BIT) ? GL_SYNC_FLUSH_COMMANDS_BIT_ : 0,
                      timeout == EGL_FOREVER ? GL_TIMEOUT_IGNORED_ : (unsigned long long)timeout);
    if (r == GL_ALREADY_SIGNALED_ || r == GL_CONDITION_SATISFIED_) OK(EGL_CONDITION_SATISFIED);
    if (r == GL_TIMEOUT_EXPIRED_) OK(EGL_TIMEOUT_EXPIRED);
    FAIL(EGL_BAD_ACCESS, EGL_FALSE);
}
EXPORT EGLint EGLAPIENTRY eglClientWaitSyncKHR(EGLDisplay dpy, EGLSyncKHR s, EGLint flags, EGLTimeKHR timeout)
{
    return eglClientWaitSync(dpy, s, flags, timeout);
}

EXPORT EGLBoolean EGLAPIENTRY eglWaitSync(EGLDisplay dpy, EGLSync s, EGLint flags)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardSync *x = sync_of(s);
    if (!x || flags) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    if (ts()->context == EGL_NO_CONTEXT) FAIL(EGL_BAD_MATCH, EGL_FALSE);
    static PFNWaitSync wait;
    if (!wait) wait = (PFNWaitSync)lgl_resolve("glWaitSync");
    if (x->gl && wait)
        wait(x->gl, 0, GL_TIMEOUT_IGNORED_);
    OK(EGL_TRUE);
}
EXPORT EGLint EGLAPIENTRY eglWaitSyncKHR(EGLDisplay dpy, EGLSyncKHR s, EGLint flags)
{
    return eglWaitSync(dpy, s, flags) ? EGL_TRUE : EGL_FALSE;
}

static EGLBoolean sync_attrib(EGLDisplay dpy, EGLSync s, EGLint a, EGLAttrib *v)
{
    if (!checked_display(dpy, 1)) return EGL_FALSE;
    LeopardSync *x = sync_of(s);
    if (!x) FAIL(EGL_BAD_PARAMETER, EGL_FALSE);
    switch (a) {
    case EGL_SYNC_TYPE: *v = EGL_SYNC_FENCE; break;
    case EGL_SYNC_CONDITION: *v = EGL_SYNC_PRIOR_COMMANDS_COMPLETE; break;
    case EGL_SYNC_STATUS: {
        static PFNGetSynciv get;
        if (!get) get = (PFNGetSynciv)lgl_resolve("glGetSynciv");
        int status = GL_SIGNALED_;
        if (x->gl && get && CGLGetCurrentContext())
            get(x->gl, GL_SYNC_STATUS_, 1, NULL, &status);
        *v = status == GL_SIGNALED_ ? EGL_SIGNALED : EGL_UNSIGNALED;
        break;
    }
    default: FAIL(EGL_BAD_ATTRIBUTE, EGL_FALSE);
    }
    OK(EGL_TRUE);
}
EXPORT EGLBoolean EGLAPIENTRY eglGetSyncAttrib(EGLDisplay dpy, EGLSync s, EGLint a, EGLAttrib *v)
{
    return sync_attrib(dpy, s, a, v);
}
EXPORT EGLBoolean EGLAPIENTRY eglGetSyncAttribKHR(EGLDisplay dpy, EGLSyncKHR s, EGLint a, EGLint *v)
{
    EGLAttrib value = 0;
    if (!sync_attrib(dpy, s, a, &value)) return EGL_FALSE;
    *v = (EGLint)value;
    return EGL_TRUE;
}
EXPORT EGLSurface EGLAPIENTRY eglCreatePbufferFromClientBuffer(EGLDisplay dpy, EGLenum t, EGLClientBuffer b, EGLConfig c, const EGLint *a)
{
    (void)t; (void)b; (void)c; (void)a;
    if (!checked_display(dpy, 1)) return EGL_NO_SURFACE;
    FAIL(EGL_BAD_CONFIG, EGL_NO_SURFACE);
}
EXPORT EGLSurface EGLAPIENTRY eglCreatePlatformPixmapSurface(EGLDisplay dpy, EGLConfig c, void *p, const EGLAttrib *a)
{
    (void)c; (void)p; (void)a;
    if (!checked_display(dpy, 1)) return EGL_NO_SURFACE;
    FAIL(EGL_BAD_CONFIG, EGL_NO_SURFACE);
}

/* ---- proc address: every EGL entry point above, then GLES (EGL_KHR_get_all_proc_addresses) ---- */
typedef struct { const char *name; void (*fn)(void); } Proc;
#define P(n) { #n, (void (*)(void))n }
static const Proc k_procs[] = {
    P(eglGetDisplay), P(eglGetPlatformDisplay), P(eglGetPlatformDisplayEXT), P(eglInitialize), P(eglTerminate),
    P(eglQueryString), P(eglGetConfigs), P(eglChooseConfig), P(eglGetConfigAttrib), P(eglCreateWindowSurface),
    P(eglCreatePlatformWindowSurface), P(eglCreatePbufferSurface), P(eglCreatePixmapSurface), P(eglDestroySurface),
    P(eglQuerySurface), P(eglSurfaceAttrib), P(eglSwapBuffers), P(eglSwapInterval), P(eglBindTexImage),
    P(eglReleaseTexImage), P(eglCopyBuffers), P(eglBindAPI), P(eglQueryAPI), P(eglCreateContext), P(eglDestroyContext),
    P(eglMakeCurrent), P(eglQueryContext), P(eglGetCurrentContext), P(eglGetCurrentSurface), P(eglGetCurrentDisplay),
    P(eglWaitClient), P(eglWaitGL), P(eglWaitNative), P(eglReleaseThread), P(eglGetError), P(eglCreateImage),
    P(eglDestroyImage), P(eglCreateSync), P(eglDestroySync), P(eglClientWaitSync), P(eglWaitSync), P(eglGetSyncAttrib),
    P(eglCreatePbufferFromClientBuffer), P(eglCreatePlatformPixmapSurface),
    P(eglCreateSyncKHR), P(eglDestroySyncKHR), P(eglClientWaitSyncKHR), P(eglWaitSyncKHR), P(eglGetSyncAttribKHR),
    P(eglCreateImageKHR), P(eglDestroyImageKHR), P(eglExportDMABUFImageQueryMESA), P(eglExportDMABUFImageMESA),
};
EXPORT __eglMustCastToProperFunctionPointerType EGLAPIENTRY eglGetProcAddress(const char *name)
{
    if (!name) return NULL;
    for (size_t i = 0; i < sizeof k_procs / sizeof k_procs[0]; i++)
        if (!strcmp(k_procs[i].name, name)) return (__eglMustCastToProperFunctionPointerType)k_procs[i].fn;
    return (__eglMustCastToProperFunctionPointerType)leopard_gles_get_proc(name);
}
