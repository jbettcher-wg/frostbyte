/*
 * FrostByte: the WebGL capability probe (docs/webgl-plan.md 1.3), run as a helper process.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 *
 * `frostbyte-shell --gl33-probe` runs only this: no AppKit, no WebKit. The UI process spawns it on a probe-cache
 * miss and waits up to 5 s, so a driver crash or a GPU hang here cannot take the browser down. It goes through
 * exactly what a web process will use: LeopardEGL (loaded by libepoxy) on the gl33 tier, an ES 3.0 context made
 * current surfaceless, GLSL ES 3.00, a draw into an FBO checked against a CPU reference, and a fence.
 *
 * Output: one line on stdout and the exit status.
 *   webgl-probe: ok es=3.0 renderer=<GL_RENDERER> max-samples=<n> max-texture=<n>        exit 0
 *   webgl-probe: fail <reason>                                                            exit 1
 *
 * SKELETON (FrostByte 0.4, P5): the gate cases below run today; the big-endian cases of section 1.3 step 5
 * (interleaved float3+ubyte4n+half2 attributes, uint16/uint32 indices, a std140 UBO, an integer texture through
 * texelFetch) and the LeopardGPU export land with the T0 probe (probes/gl33-es3.c) once LeopardEGL's gl33
 * backend (P2) and the driver's client byte-order mode (P1) exist. Until then LeopardEGL never advertises
 * EGL_LEOPARD_webgl, so this probe answers "no" at the first gate, which is the right verdict.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>

int fbWebGLProbeMain(void);

static int fail(const char *reason)
{
    printf("webgl-probe: fail %s\n", reason);
    fflush(stdout);
    return 1;
}

static int hasToken(const char *list, const char *token)
{
    size_t n = strlen(token);
    for (const char *p = list; p && (p = strstr(p, token)); p += n)
        if ((p == list || p[-1] == ' ') && (p[n] == ' ' || !p[n]))
            return 1;
    return 0;
}

static GLuint compile(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

/* A full-screen triangle from gl_VertexID alone (no enabled arrays: the WebGL 2 idiom, plan 3.3 item 7)
 * writing a constant colour; the readback must match it to within one step. */
static const char *kVertex =
    "#version 300 es\n"
    "void main() {\n"
    "    vec2 p = vec2(float((gl_VertexID & 1) << 2) - 1.0, float((gl_VertexID & 2) << 1) - 1.0);\n"
    "    gl_Position = vec4(p, 0.0, 1.0);\n"
    "}\n";
static const char *kFragment =
    "#version 300 es\n"
    "precision mediump float;\n"
    "out vec4 color;\n"
    "void main() { color = vec4(0.25, 0.5, 0.75, 1.0); }\n";

static int drawCheck(void)
{
    enum { Size = 64 };
    GLuint texture = 0, framebuffer = 0, vao = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, Size, Size, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        return fail("RGBA8 framebuffer incomplete");

    GLuint vs = compile(GL_VERTEX_SHADER, kVertex), fs = compile(GL_FRAGMENT_SHADER, kFragment);
    if (!vs || !fs)
        return fail("#version 300 es shaders do not compile");
    GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked)
        return fail("#version 300 es program does not link");

    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glViewport(0, 0, Size, Size);
    glClearColor(1, 0, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    unsigned char pixels[Size * Size * 4];
    memset(pixels, 0, sizeof pixels);
    glReadPixels(0, 0, Size, Size, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    if (glGetError() != GL_NO_ERROR)
        return fail("GL error during the draw check");
    static const unsigned char expected[4] = { 64, 128, 191, 255 };
    for (int i = 0; i < Size * Size; i++)
        for (int c = 0; c < 4; c++)
            if (abs((int)pixels[i * 4 + c] - (int)expected[c]) > 1) {
                char reason[96];
                snprintf(reason, sizeof reason, "draw check: pixel %d is %u,%u,%u,%u", i,
                         pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]);
                return fail(reason);
            }

    /* The fence round trip WebGL's prepareForDisplay() relies on. */
    GLsync sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (!sync || glClientWaitSync(sync, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull) == GL_WAIT_FAILED)
        return fail("fence round trip");
    glDeleteSync(sync);

    glDeleteProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    glDeleteVertexArrays(1, &vao);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    return 0;
}

int fbWebGLProbeMain(void)
{
    setenv("LEOPARD_WPE_GL", "gl33", 1);
    setenv("RDN_GLTHREAD", "0", 0);       /* as LeopardEGL's gl33 will: no glthread in a WebGL process */

    EGLDisplay display = eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint major = 0, minor = 0;
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor))
        return fail("eglInitialize");
    const char *vendor = eglQueryString(display, EGL_VENDOR);
    const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
    if (!hasToken(extensions, "EGL_LEOPARD_webgl")) {
        char reason[160];
        snprintf(reason, sizeof reason, "the gl33 tier is not active (no EGL_LEOPARD_webgl; EGL vendor %s)", vendor ? vendor : "?");
        return fail(reason);
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API))
        return fail("eglBindAPI(OpenGL ES)");
    static const EGLint attributes[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
    EGLContext context = eglCreateContext(display, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attributes);
    if (context == EGL_NO_CONTEXT)
        return fail("no ES 3.0 context");
    if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context))
        return fail("surfaceless make-current");
    const char *version = (const char *)glGetString(GL_VERSION);
    if (!version || strncmp(version, "OpenGL ES 3.", 12))
        return fail("GL_VERSION is not OpenGL ES 3.x");

    if (drawCheck())
        return 1;

    GLint samples = 0, maxTexture = 0;
    glGetIntegerv(GL_MAX_SAMPLES, &samples);
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTexture);
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    printf("webgl-probe: ok es=%c.%c renderer=%s max-samples=%d max-texture=%d\n", version[10], version[12],
           renderer ? renderer : "?", (int)samples, (int)maxTexture);
    fflush(stdout);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglTerminate(display);
    return 0;
}
