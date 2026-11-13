/*
 * LeopardEGL GLES layer (libGLESv2.2.dylib): GLES 2.0 presented over a CGL OpenGL 2.1
 * compatibility context. With ARB_ES2/ES3_compatibility (Mesa RadeonNI) the context already
 * compiles ES shaders and follows ES rules for VAO 0 and client arrays, so what remains is
 * presentation: ES version strings, an ES extension list matching what the desktop context can
 * really do, ES extension entry points mapped to their desktop names, and "#version 100" for
 * shaders that carry no #version (desktop would read them as GLSL 1.10).
 * Generated stubs for every other GLES 2.0/3.0 entry point are in gles_stubs.c.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gles_private.h"

/* ---- resolution ---- */

static void *g_libgl;
static const void *g_self_base;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
#if LEOPARD_EGL_WEBGL
static void *(*g_provider)(const char *);   /* gl33: RDNGLGetProcAddress (Mesa's entry points) */
static int g_es_major = 2;
static int g_modern;

LGL_EXPORT void lgl_set_provider(void *(*get_proc)(const char *), int es_major)
{
    g_provider = get_proc;
    g_es_major = es_major;
    g_modern = get_proc != NULL;
}
#endif

static void open_libs(void)
{
    g_libgl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    Dl_info info;
    if (dladdr((const void *)open_libs, &info))
        g_self_base = info.dli_fbase;
}

/* OpenGL.framework first (dispatches through CGL to the current context's renderer), then any
 * loaded image that exports the name (the RadeonNI driver exports its newer entry points), but
 * never ourselves. */
static void *real(const char *name)
{
    pthread_once(&g_once, open_libs);
#if LEOPARD_EGL_WEBGL
    if (g_provider) {                        /* gl33: straight to Mesa, past Apple's 2.1-era dispatch */
        void *m = g_provider(name);
        if (m)
            return m;
    }
#endif
    void *p = g_libgl ? dlsym(g_libgl, name) : NULL;
    if (p)
        return p;
    p = dlsym(RTLD_DEFAULT, name);
    if (p) {
        Dl_info info;
        if (dladdr(p, &info) && info.dli_fbase == g_self_base)
            return NULL;
    }
    return p;
}

static const char *const k_suffixes[] = { "OES", "EXT", "APPLE", "ARB", "ANGLE", "KHR", "NV", NULL };

LGL_EXPORT void *lgl_resolve(const char *name)
{
    void *p = real(name);
    if (p)
        return p;
    char buf[128];
    size_t n = strlen(name);
    /* ES extension name -> core desktop name: glBindVertexArrayOES -> glBindVertexArray */
    for (int i = 0; k_suffixes[i]; i++) {
        size_t s = strlen(k_suffixes[i]);
        if (n > s && n - s < sizeof buf && !strcmp(name + n - s, k_suffixes[i])) {
            memcpy(buf, name, n - s);
            buf[n - s] = 0;
            if ((p = real(buf)))
                return p;
        }
    }
    /* ES core name -> desktop extension name: glBlitFramebuffer -> glBlitFramebufferEXT */
    for (int i = 1; i <= 3; i++) {
        if (n + strlen(k_suffixes[i]) < sizeof buf) {
            snprintf(buf, sizeof buf, "%s%s", name, k_suffixes[i]);
            if ((p = real(buf)))
                return p;
        }
    }
    return NULL;
}

static long missing_entry_point(void) { return 0; }

/* ---- GLES 2.0 entry points a 2.1 driver without ARB_ES2_compatibility lacks (Apple's NVIDIA and
 * ATI drivers on 10.5; the RadeonNI driver has them all, so none of this runs there) ---- */
typedef void (*PFNDOUBLE1)(GLdouble);
typedef void (*PFNDOUBLE2)(GLdouble, GLdouble);

static void compat_glClearDepthf(GLfloat d)
{
    static PFNDOUBLE1 p;
    if (!p) p = (PFNDOUBLE1)lgl_resolve("glClearDepth");
    if (p) p(d);
}

static void compat_glDepthRangef(GLfloat n, GLfloat f)
{
    static PFNDOUBLE2 p;
    if (!p) p = (PFNDOUBLE2)lgl_resolve("glDepthRange");
    if (p) p(n, f);
}

/* Desktop GL 2.1 computes in IEEE single precision (and 32-bit integers) whatever the qualifier says. */
static void compat_glGetShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint *range, GLint *precision)
{
    (void)shadertype;
    int isFloat = precisiontype == GL_LOW_FLOAT || precisiontype == GL_MEDIUM_FLOAT || precisiontype == GL_HIGH_FLOAT;
    if (range) {
        range[0] = isFloat ? 127 : 31;
        range[1] = isFloat ? 127 : 30;
    }
    if (precision)
        *precision = isFloat ? 23 : 0;
}

static void compat_glReleaseShaderCompiler(void) { }

static void compat_glShaderBinary(GLsizei count, const GLuint *shaders, GLenum format, const void *binary, GLsizei length)
{
    (void)count; (void)shaders; (void)format; (void)binary; (void)length;   /* no binary formats (GL_NUM_SHADER_BINARY_FORMATS = 0) */
}

static void *compat_entry_point(const char *name)
{
    static const struct { const char *name; void *fn; } k_compat[] = {
        { "glClearDepthf", (void *)compat_glClearDepthf },
        { "glDepthRangef", (void *)compat_glDepthRangef },
        { "glGetShaderPrecisionFormat", (void *)compat_glGetShaderPrecisionFormat },
        { "glReleaseShaderCompiler", (void *)compat_glReleaseShaderCompiler },
        { "glShaderBinary", (void *)compat_glShaderBinary },
    };
    for (unsigned i = 0; i < sizeof k_compat / sizeof k_compat[0]; i++)
        if (!strcmp(name, k_compat[i].name))
            return k_compat[i].fn;
    return NULL;
}

void *lgl_resolve_or_trap(const char *name)
{
    void *p = lgl_resolve(name);
    if (!p)
        p = compat_entry_point(name);
    if (!p) {
        fprintf(stderr, "LeopardEGL: GL entry point %s is not available; calls do nothing\n", name);
        p = (void *)missing_entry_point;
    }
    return p;
}

LGL_EXPORT void *leopard_gles_get_proc(const char *name)
{
    if (!name || name[0] != 'g' || name[1] != 'l')
        return NULL;
    pthread_once(&g_once, open_libs);
    Dl_info info;
    void *self = NULL;
    if (dladdr((const void *)open_libs, &info))
        self = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
    void *p = self ? dlsym(self, name) : NULL;   /* our stubs and wrappers */
    Dl_info pi;
    if (p && dladdr(p, &pi) && pi.dli_fbase == g_self_base)
        return p;
    /* An ES extension entry point whose core GLES 3.0 twin we export (glTexStorage2DEXT ->
     * glTexStorage2D): hand out our stub, so every call takes the same (traceable) path. */
    size_t n = strlen(name);
    for (int i = 0; self && k_suffixes[i]; i++) {
        size_t sl = strlen(k_suffixes[i]);
        char base[128];
        if (n > sl && n - sl < sizeof base && !strcmp(name + n - sl, k_suffixes[i])) {
            memcpy(base, name, n - sl);
            base[n - sl] = 0;
            p = dlsym(self, base);
            if (p && dladdr(p, &pi) && pi.dli_fbase == g_self_base)
                return p;
        }
    }
    return lgl_resolve(name);                    /* other extension entry points, by desktop name */
}

/* ---- what the desktop context really offers ---- */

typedef const GLubyte *(*PFNGETSTRING)(GLenum);
typedef void (*PFNGETINTEGERV)(GLenum, GLint *);
typedef void (*PFNSHADERSOURCE)(GLuint, GLsizei, const GLchar *const *, const GLint *);

static PFNGETSTRING real_glGetString(void)
{
    static PFNGETSTRING p;
    if (!p) p = (PFNGETSTRING)lgl_resolve_or_trap("glGetString");
    return p;
}

/* ES extension -> what it needs on the desktop side (NULL: always there on a 2.1 context with
 * ARB_ES2_compatibility). Only extensions whose ES semantics the desktop context provides as is. */
static const struct { const char *es, *desktop; } k_extension_map[] = {
    { "GL_OES_rgb8_rgba8", NULL },
    { "GL_OES_depth24", NULL },
    { "GL_OES_element_index_uint", NULL },
    { "GL_OES_standard_derivatives", NULL },
    { "GL_OES_mapbuffer", NULL },
    { "GL_EXT_read_format_bgra", NULL },
    { "GL_EXT_texture_format_BGRA8888", NULL },   /* GL_BGRA is core since 1.2; internal formats mapped below */
    { "GL_EXT_blend_minmax", NULL },
    { "GL_EXT_unpack_subimage", NULL },
    { "GL_OES_packed_depth_stencil", "GL_EXT_packed_depth_stencil" },
    { "GL_OES_texture_npot", "GL_ARB_texture_non_power_of_two" },
    { "GL_OES_vertex_array_object", "GL_ARB_vertex_array_object" },
    { "GL_EXT_texture_storage", "GL_ARB_texture_storage" },
    { "GL_EXT_map_buffer_range", "GL_ARB_map_buffer_range" },
    { "GL_EXT_texture_rg", "GL_ARB_texture_rg" },
};

#if LEOPARD_EGL_WEBGL
/* WebGL builds, every tier (gl21 too): ES extensions WebKit's WebGL needs from the native context. NV_framebuffer_blit
 * lets ANGLE offer ANGLE_framebuffer_blit, which WebKit uses to copy a preserveDrawingBuffer canvas at every frame
 * (GraphicsContextGLANGLE::prepareTexture); without it each frame left INVALID_ENUM/INVALID_OPERATION for the page.
 * EXT_framebuffer_blit is on RadeonNI and on Apple's 10.5 NVIDIA/ATI drivers. */
static const struct { const char *es, *desktop; } k_webgl_extension_map[] = {
    { "GL_NV_framebuffer_blit", "GL_EXT_framebuffer_blit" },
};

/* gl33 only: what a 4.x compatibility context adds, by ES name (plan 3.3). Held back: timer and occlusion
 * queries (driver item D1), anything multisampled beyond the MAX_SAMPLES cap (D7). es3 = only when GLES 3.0
 * is presented. */
static const struct { const char *es, *desktop; int es3; } k_modern_extension_map[] = {
    { "GL_OES_texture_float", "GL_ARB_texture_float", 0 },
    { "GL_OES_texture_half_float", "GL_ARB_texture_float", 0 },
    { "GL_OES_texture_float_linear", "GL_ARB_texture_float", 0 },
    { "GL_OES_texture_half_float_linear", "GL_ARB_texture_float", 0 },
    { "GL_OES_depth_texture", "GL_ARB_depth_texture", 0 },
    { "GL_EXT_texture_filter_anisotropic", "GL_EXT_texture_filter_anisotropic", 0 },
    { "GL_EXT_texture_compression_s3tc", "GL_EXT_texture_compression_s3tc", 0 },
    { "GL_EXT_texture_compression_rgtc", "GL_ARB_texture_compression_rgtc", 1 },
    { "GL_EXT_texture_compression_bptc", "GL_ARB_texture_compression_bptc", 1 },
    { "GL_EXT_color_buffer_float", NULL, 1 },
    { "GL_EXT_color_buffer_half_float", NULL, 0 },
    { "GL_EXT_texture_norm16", "GL_EXT_texture_norm16", 1 },
    { "GL_EXT_clip_control", "GL_ARB_clip_control", 1 },
    { "GL_EXT_depth_clamp", "GL_ARB_depth_clamp", 1 },
    { "GL_EXT_polygon_offset_clamp", "GL_ARB_polygon_offset_clamp", 1 },
    { "GL_KHR_parallel_shader_compile", "GL_KHR_parallel_shader_compile", 0 },
};
#endif
static char *g_extensions;           /* space separated, as glGetString(GL_EXTENSIONS) */
static const char *g_extension_list[64];
static int g_extension_count;
static char *g_version;
static pthread_mutex_t g_strings_lock = PTHREAD_MUTEX_INITIALIZER;

static int desktop_has(const char *all, const char *ext)
{
    size_t n = strlen(ext);
    for (const char *p = all; p && (p = strstr(p, ext)); p += n)
        if ((p == all || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0))
            return 1;
    return 0;
}

#if LEOPARD_EGL_WEBGL
static int desktop_has_any(const char *ext)
{
    return desktop_has((const char *)real_glGetString()(GL_EXTENSIONS), ext);
}
#endif

static void build_strings(void)
{
    pthread_mutex_lock(&g_strings_lock);
    if (!g_extensions) {
        const char *desktop = (const char *)real_glGetString()(GL_EXTENSIONS);
        const char *version = (const char *)real_glGetString()(GL_VERSION);
        size_t size = 1;
        for (unsigned i = 0; i < sizeof k_extension_map / sizeof k_extension_map[0]; i++)
            size += strlen(k_extension_map[i].es) + 1;
#if LEOPARD_EGL_WEBGL
        for (unsigned i = 0; i < sizeof k_modern_extension_map / sizeof k_modern_extension_map[0]; i++)
            size += strlen(k_modern_extension_map[i].es) + 1;
        for (unsigned i = 0; i < sizeof k_webgl_extension_map / sizeof k_webgl_extension_map[0]; i++)
            size += strlen(k_webgl_extension_map[i].es) + 1;
#endif
        char *list = calloc(1, size);
        const char *hide = getenv("LEOPARD_GLES_HIDE_EXT");   /* comma/space separated, for bisecting */
        for (unsigned i = 0; i < sizeof k_extension_map / sizeof k_extension_map[0]; i++) {
            if (k_extension_map[i].desktop && !desktop_has(desktop, k_extension_map[i].desktop))
                continue;
            if (hide && strstr(hide, k_extension_map[i].es))
                continue;
            if (*list)
                strcat(list, " ");
            strcat(list, k_extension_map[i].es);
            g_extension_list[g_extension_count++] = k_extension_map[i].es;
        }
#if LEOPARD_EGL_WEBGL
        for (unsigned i = 0; i < sizeof k_webgl_extension_map / sizeof k_webgl_extension_map[0]; i++) {
            if (!desktop_has(desktop, k_webgl_extension_map[i].desktop) || (hide && strstr(hide, k_webgl_extension_map[i].es)))
                continue;
            if (*list)
                strcat(list, " ");
            strcat(list, k_webgl_extension_map[i].es);
            g_extension_list[g_extension_count++] = k_webgl_extension_map[i].es;
        }
        for (unsigned i = 0; g_modern && i < sizeof k_modern_extension_map / sizeof k_modern_extension_map[0]; i++) {
            if (k_modern_extension_map[i].es3 && g_es_major < 3)
                continue;
            if (k_modern_extension_map[i].desktop && !desktop_has_any(k_modern_extension_map[i].desktop))
                continue;
            if (hide && strstr(hide, k_modern_extension_map[i].es))
                continue;
            if (*list)
                strcat(list, " ");
            strcat(list, k_modern_extension_map[i].es);
            g_extension_list[g_extension_count++] = k_modern_extension_map[i].es;
        }
#endif
        size_t vsize = 64 + (version ? strlen(version) : 0);
        g_version = malloc(vsize);
#if LEOPARD_EGL_WEBGL
        if (g_modern) {
            /* "OpenGL ES 3.0 Mesa 26.2.4 (LeopardEGL gl33)": ANGLE parses the ES prefix, and the "Mesa x.y.z"
             * part switches on its Mesa workarounds (IsMesa, renderergl_utils.cpp). */
            const char *mesa = version ? strstr(version, "Mesa ") : NULL;
            int mesaLength = mesa ? 5 + (int)strcspn(mesa + 5, " ") : 0;
            snprintf(g_version, vsize, "OpenGL ES %d.0 %.*s (LeopardEGL gl33)", g_es_major, mesa ? mesaLength : 4,
                     mesa ? mesa : "Mesa");
        } else
#endif
        snprintf(g_version, vsize, "OpenGL ES 2.0 LeopardEGL (%s)", version ? version : "CGL");
        g_extensions = list;
    }
    pthread_mutex_unlock(&g_strings_lock);
}

/* ---- the entry points that differ between GLES 2.0 and desktop GL ---- */

LGL_EXPORT const GLubyte *GL_APIENTRY glGetString(GLenum name)
{
    switch (name) {
    case GL_VERSION:
        build_strings();
        return (const GLubyte *)g_version;
    case GL_SHADING_LANGUAGE_VERSION:
#if LEOPARD_EGL_WEBGL
        if (g_es_major >= 3)
            return (const GLubyte *)"OpenGL ES GLSL ES 3.00";
#endif
        return (const GLubyte *)"OpenGL ES GLSL ES 1.00";
    case GL_EXTENSIONS:
        build_strings();
        return (const GLubyte *)g_extensions;
    }
    return real_glGetString()(name);
}

LGL_EXPORT const GLubyte *GL_APIENTRY glGetStringi(GLenum name, GLuint index)
{
    if (name == GL_EXTENSIONS) {
        build_strings();
        return index < (GLuint)g_extension_count ? (const GLubyte *)g_extension_list[index] : NULL;
    }
    return NULL;
}

/* Whether shaders must be rewritten from GLSL ES 1.00 to desktop GLSL 1.20: the driver has no
 * ARB_ES2_compatibility (Apple's 10.5 NVIDIA/ATI drivers), so it rejects "#version 100" and precision
 * qualifiers and lacks the ES-only limits below. LEOPARD_GLES_DESKTOP_GLSL=1/0 forces it (testing the
 * rewrite on a driver that has the extension). */
static int g_desktop_glsl = -1;

static int desktop_glsl(void)
{
    if (g_desktop_glsl < 0) {
        const char *forced = getenv("LEOPARD_GLES_DESKTOP_GLSL");
        if (forced && *forced)
            g_desktop_glsl = strcmp(forced, "0") != 0;
        else {
            const char *desktop = (const char *)real_glGetString()(GL_EXTENSIONS);
            if (!desktop)
                return 0;                    /* no current context yet: decide later */
            g_desktop_glsl = !desktop_has(desktop, "GL_ARB_ES2_compatibility");
        }
        if (g_desktop_glsl)
            fprintf(stderr, "LeopardEGL: no ARB_ES2_compatibility; GLSL ES shaders are rewritten as GLSL 1.20\n");
    }
    return g_desktop_glsl;
}

LGL_EXPORT void GL_APIENTRY glGetIntegerv(GLenum pname, GLint *data)
{
    static PFNGETINTEGERV p;
    if (!p) p = (PFNGETINTEGERV)lgl_resolve_or_trap("glGetIntegerv");
    if (desktop_glsl()) {
        switch (pname) {   /* ES 2.0 limits a 2.1 context only has in components */
        case GL_MAX_VERTEX_UNIFORM_VECTORS: p(0x8B4A /* GL_MAX_VERTEX_UNIFORM_COMPONENTS */, data); *data /= 4; return;
        case GL_MAX_FRAGMENT_UNIFORM_VECTORS: p(0x8B49 /* GL_MAX_FRAGMENT_UNIFORM_COMPONENTS */, data); *data /= 4; return;
        case GL_MAX_VARYING_VECTORS: p(0x8B4B /* GL_MAX_VARYING_FLOATS */, data); *data /= 4; return;
        case GL_IMPLEMENTATION_COLOR_READ_TYPE: *data = GL_UNSIGNED_BYTE; return;
        case GL_IMPLEMENTATION_COLOR_READ_FORMAT: *data = GL_RGBA; return;
        case GL_SHADER_COMPILER: *data = GL_TRUE; return;
        case GL_NUM_SHADER_BINARY_FORMATS: *data = 0; return;
        }
    }
    switch (pname) {
    case GL_NUM_EXTENSIONS:
        build_strings();
        *data = g_extension_count;
        return;
    case GL_MAJOR_VERSION:
#if LEOPARD_EGL_WEBGL
        *data = g_es_major;
#else
        *data = 2;
#endif
        return;
#if LEOPARD_EGL_WEBGL
    case GL_MAX_SAMPLES:
        if (g_modern) {   /* capped until the driver's MSAA resolve is proven (D7); LEOPARD_GL33_MAX_SAMPLES */
            const char *cap = getenv("LEOPARD_GL33_MAX_SAMPLES");
            p(pname, data);
            int limit = cap ? atoi(cap) : 0;
            if (*data > limit) *data = limit;
            return;
        }
        break;
#endif
    case GL_MINOR_VERSION:
        *data = 0;
        return;
    }
    p(pname, data);
}

/* GLSL ES 1.00 -> desktop GLSL 1.20, in place on one joined copy of the source: "#version 100" becomes
 * "#version 120" (or is added), precision statements are blanked, the precision qualifiers are defined
 * away, and #extension lines for what 1.20 has built in (standard derivatives) are commented out. */
static int is_ident(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'; }

static char *desktop_glsl_source(GLsizei count, const GLchar *const *strings, const GLint *lengths)
{
    size_t total = 0;
    for (GLsizei i = 0; i < count; i++)
        if (strings[i])
            total += lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
    char *src = malloc(total + 1), *q = src;
    for (GLsizei i = 0; i < count; i++) {
        if (!strings[i])
            continue;
        size_t n = lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
        memcpy(q, strings[i], n);
        q += n;
    }
    *q = 0;
    static const char k_defines[] = "#define lowp\n#define mediump\n#define highp\n#line 1\n";
    char *out = malloc(total + sizeof k_defines + 32), *o = out;
    char *version = strstr(src, "#version");
    char *body = src;
    if (version) {   /* keep everything up to the end of the #version line, with 120 for the number */
        char *eol = strchr(version, '\n');
        size_t head = (size_t)(version - src);
        memcpy(o, src, head);
        o += head;
        o += sprintf(o, "#version 120\n");
        body = eol ? eol + 1 : version + strlen(version);
    } else
        o += sprintf(o, "#version 120\n");
    memcpy(o, k_defines, sizeof k_defines - 1);
    o += sizeof k_defines - 1;
    char *b0 = o;
    strcpy(o, body);
    for (char *p = b0; (p = strstr(p, "precision")); p += 9) {     /* precision <qualifier> <type>; */
        if ((p > b0 && is_ident(p[-1])) || is_ident(p[9]))
            continue;
        char *semi = strchr(p, ';');
        if (semi)
            memset(p, ' ', (size_t)(semi - p + 1));
    }
    for (char *p = b0; (p = strstr(p, "#extension GL_OES_standard_derivatives")); p += 2)
        p[0] = '/', p[1] = '/';
    free(src);
    return out;
}

/* A shader with no #version is GLSL ES 1.00 under GLES but GLSL 1.10 under desktop GL. */
LGL_EXPORT void GL_APIENTRY glShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths)
{
    static PFNSHADERSOURCE p;
    if (!p) p = (PFNSHADERSOURCE)lgl_resolve_or_trap("glShaderSource");
    if (count > 0 && desktop_glsl()) {
        char *desktop = desktop_glsl_source(count, strings, lengths);
        const GLchar *one[1] = { desktop };
        p(shader, 1, one, NULL);
        if (lgl_debug_level >= 2)
            fprintf(stderr, "LeopardEGL: shader %u as GLSL 1.20:\n%s\n", shader, desktop);
        free(desktop);
        return;
    }
    int versioned = 0;
    for (GLsizei i = 0; i < count && !versioned; i++) {
        if (!strings[i])
            continue;
        if (lengths && lengths[i] >= 0) {
            for (GLint k = 0; k + 8 <= lengths[i]; k++)
                if (!memcmp(strings[i] + k, "#version", 8)) { versioned = 1; break; }
        } else if (strstr(strings[i], "#version"))
            versioned = 1;
    }
    if (versioned || count < 0) {
        p(shader, count, strings, lengths);
        return;
    }
    const GLchar **s = malloc((count + 1) * sizeof *s);
    GLint *l = lengths ? malloc((count + 1) * sizeof *l) : NULL;
    s[0] = "#version 100\n";
    for (GLsizei i = 0; i < count; i++)
        s[i + 1] = strings[i];
    if (l) {
        l[0] = -1;
        for (GLsizei i = 0; i < count; i++)
            l[i + 1] = lengths[i];
    }
    p(shader, count + 1, s, l);
    free(s);
    free(l);
}

/* ---- LEOPARD_GLES_DEBUG=1: report shaders and programs the driver rejects ---- */

int lgl_debug_level;

__attribute__((constructor)) static void read_debug_level(void)
{
    const char *e = getenv("LEOPARD_GLES_DEBUG");
    lgl_debug_level = e ? atoi(e) : 0;
}

static int debug_enabled(void) { return lgl_debug_level > 0; }

/* LEOPARD_GLES_DEBUG=4: every call, with its thread and arguments, before it runs (driver forensics) */
void lgl_trace_call(const char *fmt, ...)
{
    char line[512];
    int n = snprintf(line, sizeof line, "GL %lx ", (unsigned long)(uintptr_t)pthread_self());
    va_list ap;
    va_start(ap, fmt);
    n += vsnprintf(line + n, sizeof line - (size_t)n - 1, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    fwrite(line, 1, (size_t)n, stderr);
}

void lgl_check_error(const char *name)
{
    static GLenum (*get_error)(void);
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static const char *reported[256];
    static int reports;
    if (lgl_debug_level >= 4)
        return;   /* level 4 traces calls (lgl_trace_call) instead of checking errors */
    if (!get_error) get_error = (GLenum (*)(void))lgl_resolve("glGetError");
    if (!get_error) return;
    GLenum e = get_error();
    if (e == GL_NO_ERROR) return;
    pthread_mutex_lock(&lock);
    int seen = 0;
    for (int i = 0; i < reports; i++)
        if (reported[i] == name) { seen = 1; break; }
    if (!seen && reports < 256) {
        reported[reports++] = name;
        fprintf(stderr, "LeopardEGL: %s -> GL error 0x%04x (first occurrence)\n", name, e);
    }
    pthread_mutex_unlock(&lock);
}

typedef void (*PFNOBJ)(GLuint);
typedef void (*PFNGETIV)(GLuint, GLenum, GLint *);
typedef void (*PFNGETLOG)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef void (*PFNGETSRC)(GLuint, GLsizei, GLsizei *, GLchar *);

LGL_EXPORT void GL_APIENTRY glCompileShader(GLuint shader)
{
    static PFNOBJ p;
    if (!p) p = (PFNOBJ)lgl_resolve_or_trap("glCompileShader");
    p(shader);
    if (!debug_enabled())
        return;
    GLint ok = 1;
    ((PFNGETIV)lgl_resolve_or_trap("glGetShaderiv"))(shader, GL_COMPILE_STATUS, &ok);
    if (ok)
        return;
    static char log[4096], src[32768];
    ((PFNGETLOG)lgl_resolve_or_trap("glGetShaderInfoLog"))(shader, sizeof log, NULL, log);
    ((PFNGETSRC)lgl_resolve_or_trap("glGetShaderSource"))(shader, sizeof src, NULL, src);
    fprintf(stderr, "LeopardEGL: shader %u failed to compile:\n%s\n--- source ---\n%s\n--- end ---\n", shader, log, src);
}

LGL_EXPORT void GL_APIENTRY glLinkProgram(GLuint program)
{
    static PFNOBJ p;
    if (!p) p = (PFNOBJ)lgl_resolve_or_trap("glLinkProgram");
    p(program);
    if (!debug_enabled())
        return;
    GLint ok = 1;
    ((PFNGETIV)lgl_resolve_or_trap("glGetProgramiv"))(program, GL_LINK_STATUS, &ok);
    if (ok)
        return;
    static char log[4096];
    ((PFNGETLOG)lgl_resolve_or_trap("glGetProgramInfoLog"))(program, sizeof log, NULL, log);
    fprintf(stderr, "LeopardEGL: program %u failed to link:\n%s\n", program, log);
}

/* LEOPARD_GLES_DEBUG=3 also traces readbacks (format, type, size, first pixel bytes). */
typedef void (*PFNREADPIXELS)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
/* ---- BGRA (EXT_texture_format_BGRA8888 / EXT_read_format_bgra) on desktop GL ----
 * WebKit's TextureMapper allocates GL_BGRA textures with internalformat == format, as the ES extension
 * requires; desktop GL rejects GL_BGRA as an internal format (GL_INVALID_VALUE), so map it to RGBA8.
 * WebKit's "BGRA8" pixels are the native 32-bit word 0xAARRGGBB (B,G,R,A bytes on little-endian). On
 * big-endian that word is A,R,G,B in memory, which desktop GL reads exactly as GL_BGRA with
 * GL_UNSIGNED_INT_8_8_8_8_REV; plain GL_UNSIGNED_BYTE would swap every channel. */
#define LGL_BGRA 0x80E1
#define LGL_BGRA8 0x93A1
#define LGL_UNSIGNED_INT_8_8_8_8_REV 0x8367

#if LEOPARD_EGL_WEBGL
static pthread_key_t g_client_le_key;
static pthread_once_t g_client_le_once = PTHREAD_ONCE_INIT;
static void make_client_le_key(void) { pthread_key_create(&g_client_le_key, NULL); }
LGL_EXPORT void lgl_set_current_client_le(int bits)
{
    pthread_once(&g_client_le_once, make_client_le_key);
    pthread_setspecific(g_client_le_key, (void *)(uintptr_t)bits);
}
static int current_client_le(void)
{
    pthread_once(&g_client_le_once, make_client_le_key);
    return (int)(uintptr_t)pthread_getspecific(g_client_le_key);
}
#endif

static GLenum bgra_type(GLenum format, GLenum type)
{
#if defined(__BIG_ENDIAN__)
#if LEOPARD_EGL_WEBGL
    /* A little-endian client context (WebGL's) has PACK/UNPACK_SWAP_BYTES on, which would swap a packed
     * 8_8_8_8_REV word too; its BGRA data is client bytes anyway. */
    if (current_client_le())
        return type;
#endif
    if (format == LGL_BGRA && type == GL_UNSIGNED_BYTE)
        return LGL_UNSIGNED_INT_8_8_8_8_REV;
#endif
    (void)format;
    return type;
}

#if LEOPARD_EGL_WEBGL
/* GLES 2.0 floating-point textures (OES_texture_float / OES_texture_half_float) are unsized: desktop GL would
 * store GL_RGBA + GL_FLOAT as RGBA8. Map to the sized float formats, and GL_HALF_FLOAT_OES (0x8D61) to
 * GL_HALF_FLOAT (0x140B), which is all desktop GL knows (plan 3.3 rule 4). */
#define LGL_HALF_FLOAT_OES 0x8D61
#define LGL_HALF_FLOAT 0x140B
static GLenum es_type(GLenum type) { return type == LGL_HALF_FLOAT_OES ? LGL_HALF_FLOAT : type; }
static GLint es_internal_format(GLint internalformat, GLenum type)
{
    if (!g_modern || (type != GL_FLOAT && type != LGL_HALF_FLOAT_OES && type != LGL_HALF_FLOAT))
        return internalformat;
    int half = type != GL_FLOAT;
    switch (internalformat) {
    case GL_RGBA: return half ? 0x881A /* RGBA16F */ : 0x8814 /* RGBA32F */;
    case GL_RGB: return half ? 0x881B /* RGB16F */ : 0x8815 /* RGB32F */;
    case GL_LUMINANCE: return half ? 0x881E /* LUMINANCE16F_ARB */ : 0x8818 /* LUMINANCE32F_ARB */;
    case GL_ALPHA: return half ? 0x881C /* ALPHA16F_ARB */ : 0x8816 /* ALPHA32F_ARB */;
    case GL_LUMINANCE_ALPHA: return half ? 0x881F /* LUMINANCE_ALPHA16F_ARB */ : 0x8819 /* LUMINANCE_ALPHA32F_ARB */;
    }
    return internalformat;
}

typedef void (*PFNENABLE)(GLenum);
typedef void (*PFNPIXELSTOREI)(GLenum, GLint);
/* Desktop compatibility contexts need these switched on to behave like GLES (plan 3.3):
 *  - gl_PointSize from the shader and gl_PointCoord (GL_VERTEX_PROGRAM_POINT_SIZE, GL_POINT_SPRITE), gl21 too;
 *  - gl33: seamless cube maps and sRGB encoding into sRGB attachments, which GLES 3.0 always does;
 *  - little-endian client contexts: GL_UNPACK_SWAP_BYTES / GL_PACK_SWAP_BYTES, so Mesa swaps client pixel data
 *    by its element size on upload and readback (plan 4.4.4; measured, probes/gl33-bridge.c B6). */
LGL_EXPORT void lgl_prepare_context(int modern, int client_le)
{
    PFNENABLE enable = (PFNENABLE)lgl_resolve_or_trap("glEnable");
    enable(0x8642 /* GL_VERTEX_PROGRAM_POINT_SIZE */);
    enable(0x8861 /* GL_POINT_SPRITE */);
    if (modern) {
        enable(0x884F /* GL_TEXTURE_CUBE_MAP_SEAMLESS */);
        enable(0x8DB9 /* GL_FRAMEBUFFER_SRGB */);
    }
    if (client_le & 1) {
        PFNPIXELSTOREI store = (PFNPIXELSTOREI)lgl_resolve_or_trap("glPixelStorei");
        store(0x0CF0 /* GL_UNPACK_SWAP_BYTES */, GL_TRUE);
        store(0x0D00 /* GL_PACK_SWAP_BYTES */, GL_TRUE);
    }
    if (lgl_debug_level)
        fprintf(stderr, "LeopardEGL: context prepared (%s%s)\n", modern ? "gl33" : "gl21", (client_le & 1) ? ", little-endian client" : "");
}
#else
#define es_type(type) (type)
#define es_internal_format(internalformat, type) (internalformat)
#endif

typedef void (*PFNTEXIMAGE2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
typedef void (*PFNTEXSUBIMAGE2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);

LGL_EXPORT void GL_APIENTRY glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei w, GLsizei h, GLint border,
                                         GLenum format, GLenum type, const void *pixels)
{
    static PFNTEXIMAGE2D p;
    if (!p) p = (PFNTEXIMAGE2D)lgl_resolve_or_trap("glTexImage2D");
    if (lgl_debug_level >= 4)
        lgl_trace_call("glTexImage2D(0x%x, %d, 0x%x, %d, %d, %d, 0x%x, 0x%x, %p)", target, level, internalformat, w, h, border, format, type, pixels);
    if (internalformat == LGL_BGRA || internalformat == LGL_BGRA8)
        internalformat = GL_RGBA8_OES;
    internalformat = es_internal_format(internalformat, type);
    p(target, level, internalformat, w, h, border, format, es_type(bgra_type(format, type)), pixels);
    if (lgl_debug_level >= 2)
        lgl_check_error("glTexImage2D");
}

LGL_EXPORT void GL_APIENTRY glTexStorage2D(GLenum target, GLsizei levels, GLenum internalformat, GLsizei w, GLsizei h)
{
    static void *p;
    if (!p && !(p = lgl_resolve("glTexStorage2D")))
        p = lgl_resolve_or_trap("glTexStorage2D");
    if (lgl_debug_level >= 4)
        lgl_trace_call("glTexStorage2D(0x%x, %d, 0x%x, %d, %d)", target, levels, internalformat, w, h);
    if (internalformat == LGL_BGRA8 || internalformat == LGL_BGRA)
        internalformat = GL_RGBA8_OES;
    ((void (*)(GLenum, GLsizei, GLenum, GLsizei, GLsizei))p)(target, levels, internalformat, w, h);
    if (lgl_debug_level)
        lgl_check_error("glTexStorage2D");
}

LGL_EXPORT void GL_APIENTRY glTexSubImage2D(GLenum target, GLint level, GLint x, GLint y, GLsizei w, GLsizei h,
                                            GLenum format, GLenum type, const void *pixels)
{
    static PFNTEXSUBIMAGE2D p;
    if (!p) p = (PFNTEXSUBIMAGE2D)lgl_resolve_or_trap("glTexSubImage2D");
    if (lgl_debug_level >= 4)
        lgl_trace_call("glTexSubImage2D(0x%x, %d, %d, %d, %d, %d, 0x%x, 0x%x, %p)", target, level, x, y, w, h, format, type, pixels);
    p(target, level, x, y, w, h, format, es_type(bgra_type(format, type)), pixels);
    if (lgl_debug_level >= 2)
        lgl_check_error("glTexSubImage2D");
}

LGL_EXPORT void GL_APIENTRY glReadPixels(GLint x, GLint y, GLsizei w, GLsizei h, GLenum format, GLenum type, void *pixels)
{
    static PFNREADPIXELS p;
    if (!p) p = (PFNREADPIXELS)lgl_resolve_or_trap("glReadPixels");
    p(x, y, w, h, format, es_type(bgra_type(format, type)), pixels);
    if (lgl_debug_level >= 3 && pixels) {
        static int traced;
        if (traced++ < 12) {
            const unsigned char *b = pixels;
            fprintf(stderr, "LeopardEGL: glReadPixels %dx%d+%d+%d format 0x%04x type 0x%04x  bytes %02x %02x %02x %02x | %02x %02x %02x %02x\n",
                    w, h, x, y, format, type, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]);
        }
    }
    if (lgl_debug_level >= 2)
        lgl_check_error("glReadPixels");
}

/* ---- textures backed by LeopardGPU shared buffers (zero-copy frames, see egl.c) ---- */

typedef struct { void *group; GLuint texture; unsigned int buffer; } TextureBuffer;
static TextureBuffer g_texture_buffers[512];
static pthread_mutex_t g_texture_buffers_lock = PTHREAD_MUTEX_INITIALIZER;

LGL_EXPORT void lgl_register_texture_buffer(void *group, unsigned int texture, unsigned int buffer_id)
{
    pthread_mutex_lock(&g_texture_buffers_lock);
    TextureBuffer *free_slot = NULL;
    for (unsigned i = 0; i < sizeof g_texture_buffers / sizeof g_texture_buffers[0]; i++) {
        TextureBuffer *t = &g_texture_buffers[i];
        if (t->buffer && t->group == group && t->texture == texture) { t->buffer = buffer_id; free_slot = NULL; goto out; }
        if (!t->buffer && !free_slot) free_slot = t;
    }
    if (free_slot) { free_slot->group = group; free_slot->texture = texture; free_slot->buffer = buffer_id; }
    else fprintf(stderr, "LeopardEGL: texture/buffer table full; buffer %u will leak\n", buffer_id);
out:
    pthread_mutex_unlock(&g_texture_buffers_lock);
}

LGL_EXPORT unsigned int lgl_lookup_texture_buffer(void *group, unsigned int texture)
{
    unsigned int id = 0;
    pthread_mutex_lock(&g_texture_buffers_lock);
    for (unsigned i = 0; i < sizeof g_texture_buffers / sizeof g_texture_buffers[0] && !id; i++)
        if (g_texture_buffers[i].buffer && g_texture_buffers[i].group == group && g_texture_buffers[i].texture == texture)
            id = g_texture_buffers[i].buffer;
    pthread_mutex_unlock(&g_texture_buffers_lock);
    return id;
}

static pthread_key_t g_group_key;
static pthread_once_t g_group_once = PTHREAD_ONCE_INIT;
static void make_group_key(void) { pthread_key_create(&g_group_key, NULL); }

LGL_EXPORT void lgl_set_current_group(void *group)
{
    pthread_once(&g_group_once, make_group_key);
    pthread_setspecific(g_group_key, group);
}

static void *current_group(void)
{
    pthread_once(&g_group_once, make_group_key);
    return pthread_getspecific(g_group_key);
}

typedef void *(*PFNCGLGETCURRENT)(void);
typedef int (*PFNBUFFERRELEASE)(void *, unsigned int);
typedef void (*PFNDELETETEXTURES)(GLsizei, const GLuint *);

LGL_EXPORT void GL_APIENTRY glDeleteTextures(GLsizei n, const GLuint *textures)
{
    static PFNDELETETEXTURES p;
    static PFNCGLGETCURRENT get_current;
    static PFNBUFFERRELEASE release;
    if (!p) p = (PFNDELETETEXTURES)lgl_resolve_or_trap("glDeleteTextures");
    pthread_once(&g_once, open_libs);
    if (!get_current && g_libgl) get_current = (PFNCGLGETCURRENT)dlsym(g_libgl, "CGLGetCurrentContext");
    void *ctx = get_current ? get_current() : NULL;
    void *group = ctx ? current_group() : NULL;
    for (GLsizei i = 0; group && i < n; i++) {
        unsigned int id = 0;
        pthread_mutex_lock(&g_texture_buffers_lock);
        for (unsigned k = 0; k < sizeof g_texture_buffers / sizeof g_texture_buffers[0]; k++) {
            TextureBuffer *t = &g_texture_buffers[k];
            if (t->buffer && t->group == group && t->texture == textures[i]) { id = t->buffer; t->buffer = 0; break; }
        }
        pthread_mutex_unlock(&g_texture_buffers_lock);
        if (id) {
            if (!release) release = (PFNBUFFERRELEASE)dlsym(RTLD_DEFAULT, "LeopardGPU_BufferRelease");
            if (release) release(ctx, id);
        }
    }
    p(n, textures);
    if (lgl_debug_level >= 2) lgl_check_error("glDeleteTextures");
}
