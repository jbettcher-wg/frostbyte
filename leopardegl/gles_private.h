/* LeopardEGL GLES layer, internal interface. Copyright (c) 2026 Jordan Bettcher. SPDX-License-Identifier: MIT */
#ifndef LEOPARDEGL_GLES_PRIVATE_H
#define LEOPARDEGL_GLES_PRIVATE_H

#define LGL_EXPORT __attribute__((visibility("default")))

/* The implementation of a GL entry point (desktop GL on the current CGL context), or NULL. */
LGL_EXPORT void *lgl_resolve(const char *name);   /* also used by libEGL */
/* Same, but never NULL: a missing entry point resolves to a logged no-op returning 0. */
void *lgl_resolve_or_trap(const char *name);
/* For eglGetProcAddress: our exported entry point (stub or wrapper), else the mapped desktop one. */
LGL_EXPORT void *leopard_gles_get_proc(const char *name);

/* Textures whose storage LeopardEGL replaced with a LeopardGPU shared buffer (eglCreateImage):
 * the buffer is released when the texture is deleted. group = CGL share group. */
LGL_EXPORT void lgl_register_texture_buffer(void *group, unsigned int texture, unsigned int buffer_id);
LGL_EXPORT unsigned int lgl_lookup_texture_buffer(void *group, unsigned int texture);
/* eglMakeCurrent reports the current context's share group (per thread). */
LGL_EXPORT void lgl_set_current_group(void *group);

/* LEOPARD_GLES_DEBUG=2: glGetError after every call, reported per entry point. */
extern int lgl_debug_level;
void lgl_check_error(const char *name);
void lgl_trace_call(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
