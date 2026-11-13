/*
 * FrostByte: a Cocoa WPEPlatform backend for Mac OS X 10.5 (ppc64). See wpe-cocoa.h.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <unistd.h>
#include "wpe-cocoa.h"
#include <string.h>

/* ------------------------------------------------------------------------------------------ */
/* Cocoa event pump: GLib's main loop (which WebKit runs) is primary; Cocoa is drained from it. */

static guint s_pumpSource;

static gboolean cocoaPump(gpointer data)
{
    (void)data;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate distantPast]
                                         inMode:NSDefaultRunLoopMode dequeue:YES]))
        [NSApp sendEvent:event];
    [NSApp updateWindows];
    [pool release];
    return G_SOURCE_CONTINUE;
}

/* GLib (WebKit's loop), not Cocoa, calls into this backend, so every entry point that touches
 * Cocoa needs its own autorelease pool. */
#define FB_POOL_BEGIN NSAutoreleasePool *fbPool = [[NSAutoreleasePool alloc] init]
#define FB_POOL_END [fbPool release]

/* ------------------------------------------------------------------------------------------ */
/* Input translation */

static WPEModifiers keyboardModifiers(NSUInteger flags)
{
    guint m = 0;
    if (flags & NSShiftKeyMask) m |= WPE_MODIFIER_KEYBOARD_SHIFT;
    if (flags & NSControlKeyMask) m |= WPE_MODIFIER_KEYBOARD_CONTROL;
    if (flags & NSAlternateKeyMask) m |= WPE_MODIFIER_KEYBOARD_ALT;
    if (flags & NSCommandKeyMask) m |= WPE_MODIFIER_KEYBOARD_META;
    if (flags & NSAlphaShiftKeyMask) m |= WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
    return (WPEModifiers)m;
}

static guint32 eventTime(NSEvent *event)
{
    return (guint32)([event timestamp] * 1000.0);
}

/* Mac virtual key code (kVK_*, the physical key) -> X11/evdev key code (evdev + 8). WebKit's WPE port
 * derives the DOM KeyboardEvent.code from the hardware key code with the X11 numbering; passing the Mac
 * code through made "v" arrive as code "Escape", "l" as "ControlLeft", "5" as "Tab" and so on, which
 * sites that read event.code (YouTube's search box and shortcuts) acted on. 0 = no equivalent. */
static const unsigned char kMacToX11Keycode[128] = {
    /* 0x00 */ 38, 39, 40, 41, 43, 42, 52, 53, 54, 55, 94, 56, 24, 25, 26, 27,
    /* 0x10 */ 29, 28, 10, 11, 12, 13, 15, 14, 21, 18, 16, 20, 17, 19, 35, 32,
    /* 0x20 */ 30, 34, 31, 33, 36, 46, 44, 48, 45, 47, 51, 59, 61, 57, 58, 60,
    /* 0x30 */ 23, 65, 49, 22, 104, 9, 134, 133, 50, 66, 64, 37, 62, 108, 105, 0,
    /* 0x40 */ 195, 91, 0, 63, 0, 86, 0, 77, 123, 122, 121, 106, 104, 0, 82, 196,
    /* 0x50 */ 197, 125, 90, 87, 88, 89, 83, 84, 85, 79, 198, 80, 81, 132, 97, 129,
    /* 0x60 */ 71, 72, 73, 69, 74, 75, 0, 95, 0, 191, 194, 192, 0, 76, 135, 96,
    /* 0x70 */ 0, 193, 118, 110, 112, 119, 70, 115, 68, 117, 67, 113, 114, 116, 111, 0,
};

static guint x11KeycodeForEvent(NSEvent *event)
{
    unsigned short code = [event keyCode];
    return code < 128 ? kMacToX11Keycode[code] : 0;
}

/* NSEvent character -> X11/WPE keysym. */
static guint keysymForCharacter(unichar c)
{
    switch (c) {
    case '\r': case 0x03: return WPE_KEY_Return;           /* 0x03 = keypad Enter */
    case '\t': return WPE_KEY_Tab;
    case 0x19: return WPE_KEY_ISO_Left_Tab;                /* shift-tab */
    case 0x1b: return WPE_KEY_Escape;
    case 0x7f: case '\b': return WPE_KEY_BackSpace;        /* the Mac "delete" key */
    case NSDeleteFunctionKey: return WPE_KEY_Delete;
    case NSUpArrowFunctionKey: return WPE_KEY_Up;
    case NSDownArrowFunctionKey: return WPE_KEY_Down;
    case NSLeftArrowFunctionKey: return WPE_KEY_Left;
    case NSRightArrowFunctionKey: return WPE_KEY_Right;
    case NSHomeFunctionKey: return WPE_KEY_Home;
    case NSEndFunctionKey: return WPE_KEY_End;
    case NSPageUpFunctionKey: return WPE_KEY_Page_Up;
    case NSPageDownFunctionKey: return WPE_KEY_Page_Down;
    case NSInsertFunctionKey: return WPE_KEY_Insert;
    case NSHelpFunctionKey: return WPE_KEY_Help;
    }
    if (c >= NSF1FunctionKey && c <= NSF24FunctionKey)
        return WPE_KEY_F1 + (c - NSF1FunctionKey);
    if (c >= 0xF700 && c <= 0xF8FF)                         /* other Cocoa function keys */
        return 0;
    if (c < 0x20)
        return 0;
    if (c < 0x100)
        return c;                                           /* Latin-1 keysyms are the code point */
    return 0x01000000 | c;                                  /* Unicode keysym */
}

/* ------------------------------------------------------------------------------------------ */
/* The NSView behind a WPEViewCocoa */

@interface FBWPEView : NSView {
@public
    WPEView *wpeView;              /* not retained: the GObject owns us */
    CGImageRef image;              /* current frame, backed by the committed WPEBuffer */
    guint buttonState;             /* WPE_MODIFIER_POINTER_BUTTON* currently held */
    NSCursor *cursor;              /* what WebKit asked for over this view */
    NSOpenGLContext *glContext;    /* zero-copy frames: shared GPU buffers drawn with OpenGL */
    BOOL surfaceStale;             /* the GL surface was resized during a live resize, see -reattachSurface */
}
- (void)setPageCursor:(NSCursor *)c;
- (BOOL)presentDMABuf:(WPEBufferDMABuf *)buffer;
- (void)leaveGL;
@end

static void presentCommittedAgain(WPEView *view);

/* ---- zero-copy frames (LeopardGPU shared buffers from the web process, see leopardegl/egl.c) ---- */
#define LEOPARD_RADEONNI_COMPAT_RENDERER 0x00021a00
typedef int (*PFN_LGPU_Import)(void *, int, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, uint32_t *);
typedef int (*PFN_LGPU_BindTexture)(void *, uint32_t, GLuint);
typedef int (*PFN_LGPU_Release)(void *, uint32_t);
static PFN_LGPU_Import s_lgpuImport;
static PFN_LGPU_BindTexture s_lgpuBind;
static PFN_LGPU_Release s_lgpuRelease;

typedef struct {
    uint32_t id;
    GLuint texture;
    CGLContextObj cgl;
} FBImportedBuffer;

static void importedBufferFree(gpointer data)
{
    FBImportedBuffer *imported = data;
    CGLContextObj previous = CGLGetCurrentContext();
    CGLSetCurrentContext(imported->cgl);
    glDeleteTextures(1, &imported->texture);
    if (s_lgpuRelease)
        s_lgpuRelease(imported->cgl, imported->id);
    CGLSetCurrentContext(previous);
    CGLReleaseContext(imported->cgl);
    g_free(imported);
}

@implementation FBWPEView

- (BOOL)isFlipped { return NO; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

- (void)dealloc
{
    if (image)
        CGImageRelease(image);
    [cursor release];
    [glContext clearDrawable];
    [glContext release];
    [super dealloc];
}

/* Back to CoreGraphics (shared-memory frames). */
- (void)leaveGL
{
    if (glContext && [glContext view])
        [glContext clearDrawable];
}

/* After a window is resized by dragging (live resize), the window server's GL compositor keeps texturing this
 * view's GL surface at its size from before the drag (CGSGetSurfaceBounds reports the new bounds; the stale
 * size is in the compositor's texture of our drawable, RadeonNI on board 1, 10.5.8). Frames look right while
 * the server copies the surface straight to the screen, but whenever it composites it, because another window
 * overlaps the page (the link-status bubble on every link hover, a menu, a utility window), the page shrinks or
 * grows by old/new size with edge-clamped streaks past the frame. -update after the drag doesn't help (same
 * size, no-op); detaching and re-attaching the drawable does, but not at once: a re-attach 6 ms after
 * -viewDidEndLiveResize still left it stale, 20, 150 and 300 ms fixed it (measured on board 1). */
- (void)reattachSurface
{
    surfaceStale = NO;
    if (!glContext || [glContext view] != self)
        return;
    [glContext clearDrawable];
    [glContext setView:self];
}

static gboolean reattachAfterLiveResize(gpointer data)
{
    FBWPEView *view = data;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (view->surfaceStale && ![view inLiveResize] && view->wpeView) {
        [view reattachSurface];
        presentCommittedAgain(view->wpeView);   /* the new surface is empty until something draws into it */
    }
    [pool release];
    [view release];
    return G_SOURCE_REMOVE;
}

- (void)viewDidEndLiveResize
{
    [super viewDidEndLiveResize];
    if (surfaceStale)
        g_timeout_add(150, reattachAfterLiveResize, [self retain]);   /* once the window server is done with it */
}

- (BOOL)presentDMABuf:(WPEBufferDMABuf *)buffer
{
    if (!glContext) {
        NSOpenGLPixelFormatAttribute attributes[] = {
            NSOpenGLPFARendererID, LEOPARD_RADEONNI_COMPAT_RENDERER, NSOpenGLPFAAccelerated,
            NSOpenGLPFADoubleBuffer, NSOpenGLPFANoRecovery, 0
        };
        NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
        if (!format)
            return NO;
        glContext = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
        [format release];
        if (!glContext)
            return NO;
        GLint interval = 0;
        [glContext setValues:&interval forParameter:NSOpenGLCPSwapInterval];
        s_lgpuImport = (PFN_LGPU_Import)dlsym(RTLD_DEFAULT, "LeopardGPU_BufferImport");
        s_lgpuBind = (PFN_LGPU_BindTexture)dlsym(RTLD_DEFAULT, "LeopardGPU_BufferBindTexture");
        s_lgpuRelease = (PFN_LGPU_Release)dlsym(RTLD_DEFAULT, "LeopardGPU_BufferRelease");
    }
    if (!s_lgpuImport || !s_lgpuBind)
        return NO;
    if ([glContext view] != self)
        [glContext setView:self];
    [glContext makeCurrentContext];
    CGLContextObj cgl = [glContext CGLContextObj];

    WPEBuffer *wpeBuffer = WPE_BUFFER(buffer);
    int width = wpe_buffer_get_width(wpeBuffer), height = wpe_buffer_get_height(wpeBuffer);
    FBImportedBuffer *imported = g_object_get_data(G_OBJECT(buffer), "frostbyte-gl");
    if (!imported) {
        uint32_t id = 0;
        int fd = dup(wpe_buffer_dma_buf_get_fd(buffer, 0));
        int result = fd < 0 ? -1 : s_lgpuImport(cgl, fd, width, height, wpe_buffer_dma_buf_get_format(buffer),
                                                wpe_buffer_dma_buf_get_offset(buffer, 0),
                                                wpe_buffer_dma_buf_get_stride(buffer, 0),
                                                wpe_buffer_dma_buf_get_modifier(buffer), &id);
        if (fd >= 0)
            close(fd);
        if (result) {
            fprintf(stderr, "frostbyte: LeopardGPU_BufferImport failed (%d) for a %dx%d frame\n", result, width, height);
            return NO;
        }
        GLuint texture = 0;
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        if (s_lgpuBind(cgl, id, texture)) {
            glDeleteTextures(1, &texture);
            if (s_lgpuRelease) s_lgpuRelease(cgl, id);
            return NO;
        }
        imported = g_new0(FBImportedBuffer, 1);
        imported->id = id;
        imported->texture = texture;
        imported->cgl = CGLRetainContext(cgl);
        g_object_set_data_full(G_OBJECT(buffer), "frostbyte-gl", imported, importedBufferFree);
    }

    /* Top-anchored like the CoreGraphics path. FROSTBYTE_GL_FLIP=1 flips the texture vertically. */
    static int flip = -1;
    if (flip < 0) flip = getenv("FROSTBYTE_GL_FLIP") && *getenv("FROSTBYTE_GL_FLIP") == '1';
    NSRect bounds = [self bounds];
    glViewport(0, 0, (GLsizei)bounds.size.width, (GLsizei)bounds.size.height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, bounds.size.width, 0, bounds.size.height, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glClearColor(1, 1, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, imported->texture);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    GLfloat top = bounds.size.height, bottom = bounds.size.height - height;
    GLfloat vTop = flip ? 1 : 0, vBottom = flip ? 0 : 1;
    glBegin(GL_QUADS);
    glTexCoord2f(0, vBottom); glVertex2f(0, bottom);
    glTexCoord2f(1, vBottom); glVertex2f(width, bottom);
    glTexCoord2f(1, vTop);    glVertex2f(width, top);
    glTexCoord2f(0, vTop);    glVertex2f(0, top);
    glEnd();
    glDisable(GL_TEXTURE_2D);
    [glContext flushBuffer];
    return YES;
}

- (void)setPageCursor:(NSCursor *)c
{
    if (c == cursor)
        return;
    [cursor release];
    cursor = [c retain];
    [[self window] invalidateCursorRectsForView:self];
    [cursor set];
}

/* AppKit re-applies cursor rects whenever it likes; keep ours current. */
- (void)resetCursorRects
{
    [self addCursorRect:[self visibleRect] cursor:cursor ? cursor : [NSCursor arrowCursor]];
}

- (void)setFrameImage:(CGImageRef)newImage
{
    if (image)
        CGImageRelease(image);
    image = newImage;
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    CGContextRef cg = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    NSRect b = [self bounds];
    if (!image) {
        CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
        CGContextFillRect(cg, NSRectToCGRect(b));
        return;
    }
    /* WPE frames are top-left anchored; the view is not flipped, so place the image's top edge
     * at the top of the view. CGContextDrawImage draws images upright in this space. */
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    CGContextSetBlendMode(cg, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
    CGContextDrawImage(cg, CGRectMake(0, b.size.height - h, w, h), image);
}

/* The view may sit anywhere inside the browser window (under a toolbar, beside a tab bar), so it
 * reports its own size to WPE rather than the window doing it. */
- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    if (glContext && [glContext view] == self) {
        [glContext update];
        if ([self inLiveResize])
            surfaceStale = YES;
    }
    if (wpeView)
        wpe_view_resized(wpeView, (int)size.width, (int)size.height);
}

/* Keyboard focus belongs to the page only while this view is the first responder of a key window
 * (the location field may hold it instead). */
- (BOOL)becomeFirstResponder
{
    if (wpeView && [[self window] isKeyWindow])
        wpe_view_focus_in(wpeView);
    return YES;
}
- (BOOL)resignFirstResponder
{
    if (wpeView)
        wpe_view_focus_out(wpeView);
    return YES;
}

- (double)wpeY:(NSPoint)p { return [self bounds].size.height - p.y; }

- (void)sendPointer:(NSEvent *)event type:(WPEEventType)type button:(guint)button
{
    if (!wpeView)
        return;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    guint mask = button ? (WPE_MODIFIER_POINTER_BUTTON1 << (button - 1)) : 0;
    if (type == WPE_EVENT_POINTER_DOWN)
        buttonState |= mask;
    WPEModifiers modifiers = (WPEModifiers)(keyboardModifiers([event modifierFlags]) | buttonState);
    WPEEvent *e;
    if (type == WPE_EVENT_POINTER_MOVE || type == WPE_EVENT_POINTER_ENTER || type == WPE_EVENT_POINTER_LEAVE)
        e = wpe_event_pointer_move_new(type, wpeView, WPE_INPUT_SOURCE_MOUSE, eventTime(event), modifiers,
                                       p.x, [self wpeY:p], [event deltaX], [event deltaY]);
    else
        /* WPE accepts a click count only on button-down (asserts otherwise and returns NULL). */
        e = wpe_event_pointer_button_new(type, wpeView, WPE_INPUT_SOURCE_MOUSE, eventTime(event), modifiers,
                                         button, p.x, [self wpeY:p],
                                         type == WPE_EVENT_POINTER_DOWN ? (guint)[event clickCount] : 0);
    if (type == WPE_EVENT_POINTER_UP)
        buttonState &= ~mask;
    if (!e)
        return;   /* WPE rejected the event (a g_return_val_if_fail): drop it, never crash */
    wpe_view_event(wpeView, e);
    wpe_event_unref(e);
}

/* NSEvent buttonNumber 0/1/2 = left/right/middle; WPE (X11 numbering) 1/2/3 = left/middle/right. */
static guint wpeButton(NSEvent *event)
{
    switch ([event buttonNumber]) {
    case 0: return 1;
    case 1: return 3;
    case 2: return 2;
    default: return (guint)[event buttonNumber] + 1;
    }
}

- (void)mouseDown:(NSEvent *)e { [[self window] makeFirstResponder:self]; [self sendPointer:e type:WPE_EVENT_POINTER_DOWN button:1]; }
- (void)mouseUp:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_UP button:1]; }
- (void)rightMouseDown:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_DOWN button:3]; }
- (void)rightMouseUp:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_UP button:3]; }
- (void)otherMouseDown:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_DOWN button:wpeButton(e)]; }
- (void)otherMouseUp:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_UP button:wpeButton(e)]; }
- (void)mouseMoved:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_MOVE button:0]; }
- (void)mouseDragged:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_MOVE button:0]; }
- (void)rightMouseDragged:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_MOVE button:0]; }
- (void)otherMouseDragged:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_MOVE button:0]; }
- (void)mouseEntered:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_ENTER button:0]; }
- (void)mouseExited:(NSEvent *)e { [self sendPointer:e type:WPE_EVENT_POINTER_LEAVE button:0]; }

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self trackingAreas])
        [self removeTrackingArea:area];
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:[self bounds]
        options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:area];
    [area release];
}

- (void)scrollWheel:(NSEvent *)event
{
    if (!wpeView)
        return;
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    /* Cocoa: positive deltaY scrolls towards the top. WPE/GDK: positive delta_y scrolls down. */
    WPEEvent *e = wpe_event_scroll_new(wpeView, WPE_INPUT_SOURCE_MOUSE, eventTime(event),
                                       keyboardModifiers([event modifierFlags]),
                                       -[event deltaX], -[event deltaY], FALSE, FALSE, p.x, [self wpeY:p]);
    if (!e)
        return;   /* WPE rejected the event (a g_return_val_if_fail): drop it, never crash */
    wpe_view_event(wpeView, e);
    wpe_event_unref(e);
}

- (void)sendKey:(NSEvent *)event type:(WPEEventType)type
{
    if (!wpeView)
        return;
    NSUInteger flags = [event modifierFlags];
    /* With Command or Control held, report the base key so shortcuts like Cmd-C arrive as 'c'. */
    NSString *chars = (flags & (NSCommandKeyMask | NSControlKeyMask)) ? [event charactersIgnoringModifiers] : [event characters];
    if (![chars length])
        chars = [event charactersIgnoringModifiers];
    guint keyval = [chars length] ? keysymForCharacter([chars characterAtIndex:0]) : 0;
    if (!keyval)
        return;
    WPEEvent *e = wpe_event_keyboard_new(type, wpeView, WPE_INPUT_SOURCE_KEYBOARD, eventTime(event),
                                         keyboardModifiers(flags), x11KeycodeForEvent(event), keyval);
    if (!e)
        return;   /* WPE rejected the event (a g_return_val_if_fail): drop it, never crash */
    wpe_view_event(wpeView, e);
    wpe_event_unref(e);
}

- (void)keyDown:(NSEvent *)e { [self sendKey:e type:WPE_EVENT_KEYBOARD_KEY_DOWN]; }
- (void)keyUp:(NSEvent *)e { [self sendKey:e type:WPE_EVENT_KEYBOARD_KEY_UP]; }

/* Let Cmd-key combinations reach the page as well as the menu bar. */
- (BOOL)performKeyEquivalent:(NSEvent *)e { (void)e; return NO; }

@end

/* ------------------------------------------------------------------------------------------ */
/* WPEToplevelCocoa: one NSWindow */

struct _WPEToplevelCocoa {
    WPEToplevel parent;
    NSWindow *window;
    id delegate;
    NSView *viewHost;      /* where views go (not retained: part of the window); nil = whole window */
    WPEToplevelCocoaShouldCloseFunc shouldClose;
    gpointer shouldCloseData;
};

G_DEFINE_FINAL_TYPE(WPEToplevelCocoa, wpe_toplevel_cocoa, WPE_TYPE_TOPLEVEL)

@interface FBWPEWindowDelegate : NSObject {
@public
    WPEToplevelCocoa *toplevel;
}
@end

@implementation FBWPEWindowDelegate
- (void)windowDidResize:(NSNotification *)n
{
    NSWindow *w = [n object];
    NSSize s = [[w contentView] bounds].size;
    wpe_toplevel_resized(WPE_TOPLEVEL(toplevel), (int)s.width, (int)s.height); /* views report their own size */
}
- (BOOL)windowShouldClose:(id)sender
{
    (void)sender;
    if (toplevel->shouldClose && !toplevel->shouldClose(toplevel, toplevel->shouldCloseData))
        return NO;
    wpe_toplevel_closed(WPE_TOPLEVEL(toplevel));
    return YES;
}
static gboolean focusCallback(WPEToplevel *t, WPEView *view, gpointer in)
{
    NSWindow *w = WPE_TOPLEVEL_COCOA(t)->window;
    if (!in)
        wpe_view_focus_out(view);
    else if ([w firstResponder] == (NSResponder *)wpe_view_cocoa_get_nsview(WPE_VIEW_COCOA(view)))
        wpe_view_focus_in(view);
    return FALSE;
}
/* WebKit takes "window is active" (caret blink, focus rings, selection colour) from
 * WPE_TOPLEVEL_STATE_ACTIVE, and keyboard focus from the view. */
static void setActive(WPEToplevel *t, gboolean active)
{
    WPEToplevelState state = wpe_toplevel_get_state(t);
    state = active ? (WPEToplevelState)(state | WPE_TOPLEVEL_STATE_ACTIVE) : (WPEToplevelState)(state & ~WPE_TOPLEVEL_STATE_ACTIVE);
    wpe_toplevel_state_changed(t, state);
    wpe_toplevel_foreach_view(t, focusCallback, active ? GINT_TO_POINTER(1) : NULL);
}
- (void)windowDidBecomeKey:(NSNotification *)n { (void)n; setActive(WPE_TOPLEVEL(toplevel), TRUE); }
- (void)windowDidResignKey:(NSNotification *)n { (void)n; setActive(WPE_TOPLEVEL(toplevel), FALSE); }
@end

static void wpe_toplevel_cocoa_constructed(GObject *object)
{
    FB_POOL_BEGIN;
    G_OBJECT_CLASS(wpe_toplevel_cocoa_parent_class)->constructed(object);
    WPEToplevelCocoa *self = WPE_TOPLEVEL_COCOA(object);
    NSRect frame = NSMakeRect(80, 80, 1024, 700);
    /* Textured: Leopard's unified title bar and toolbar, whose background the browser can recolour
     * (dark appearance). Note: in a textured window windowBackgroundColor is AppKit's gradient
     * pattern, slow to the point of hanging when used to fill views; don't fill with it. */
    self->window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
                  | NSTexturedBackgroundWindowMask
        backing:NSBackingStoreBuffered defer:NO];
    [self->window setReleasedWhenClosed:NO];
    [self->window setAcceptsMouseMovedEvents:YES];
    [self->window setTitle:@"FrostByte"];
    FBWPEWindowDelegate *delegate = [[FBWPEWindowDelegate alloc] init];
    delegate->toplevel = self;
    self->delegate = delegate;
    [self->window setDelegate:delegate];
    wpe_toplevel_resized(WPE_TOPLEVEL(self), (int)frame.size.width, (int)frame.size.height);
    FB_POOL_END;
}

static void wpe_toplevel_cocoa_dispose(GObject *object)
{
    FB_POOL_BEGIN;
    WPEToplevelCocoa *self = WPE_TOPLEVEL_COCOA(object);
    if (self->window) {
        [self->window setDelegate:nil];
        [self->window orderOut:nil];
        [self->window release];
        self->window = nil;
    }
    if (self->delegate) {
        [self->delegate release];
        self->delegate = nil;
    }
    G_OBJECT_CLASS(wpe_toplevel_cocoa_parent_class)->dispose(object);
    FB_POOL_END;
}

static void wpe_toplevel_cocoa_set_title(WPEToplevel *toplevel, const char *title)
{
    WPEToplevelCocoa *self = WPE_TOPLEVEL_COCOA(toplevel);
    FB_POOL_BEGIN;
    NSString *s = title ? [NSString stringWithUTF8String:title] : nil;
    [self->window setTitle:s ? s : @"FrostByte"];
    FB_POOL_END;
}

static gboolean wpe_toplevel_cocoa_resize(WPEToplevel *toplevel, int width, int height)
{
    FB_POOL_BEGIN;
    [WPE_TOPLEVEL_COCOA(toplevel)->window setContentSize:NSMakeSize(width, height)];
    FB_POOL_END;
    return TRUE; /* windowDidResize: reports the size that actually took */
}

static gboolean wpe_toplevel_cocoa_set_fullscreen(WPEToplevel *toplevel, gboolean fullscreen)
{
    (void)toplevel; (void)fullscreen;
    return FALSE; /* TODO: -[NSView enterFullScreenMode:withOptions:] (10.5) */
}

static void wpe_toplevel_cocoa_class_init(WPEToplevelCocoaClass *klass)
{
    GObjectClass *objectClass = G_OBJECT_CLASS(klass);
    objectClass->constructed = wpe_toplevel_cocoa_constructed;
    objectClass->dispose = wpe_toplevel_cocoa_dispose;
    WPEToplevelClass *toplevelClass = WPE_TOPLEVEL_CLASS(klass);
    toplevelClass->set_title = wpe_toplevel_cocoa_set_title;
    toplevelClass->resize = wpe_toplevel_cocoa_resize;
    toplevelClass->set_fullscreen = wpe_toplevel_cocoa_set_fullscreen;
}

static void wpe_toplevel_cocoa_init(WPEToplevelCocoa *self) { (void)self; }

void wpe_toplevel_cocoa_set_view_host(WPEToplevelCocoa *toplevel, void *host)
{
    g_return_if_fail(WPE_IS_TOPLEVEL_COCOA(toplevel));
    toplevel->viewHost = (NSView *)host;
}

void wpe_toplevel_cocoa_set_should_close_func(WPEToplevelCocoa *toplevel, WPEToplevelCocoaShouldCloseFunc func, gpointer userData)
{
    g_return_if_fail(WPE_IS_TOPLEVEL_COCOA(toplevel));
    toplevel->shouldClose = func;
    toplevel->shouldCloseData = userData;
}

void *wpe_toplevel_cocoa_get_window(WPEToplevelCocoa *toplevel)
{
    g_return_val_if_fail(WPE_IS_TOPLEVEL_COCOA(toplevel), NULL);
    return toplevel->window;
}

/* ------------------------------------------------------------------------------------------ */
/* WPEViewCocoa */

struct _WPEViewCocoa {
    WPEView parent;
    FBWPEView *nsview;
    WPEBuffer *pendingBuffer;
    WPEBuffer *committedBuffer;
    GSource *frameSource;
    gint64 lastFrameTime;
};

G_DEFINE_FINAL_TYPE(WPEViewCocoa, wpe_view_cocoa, WPE_TYPE_VIEW)

static void releaseBytes(void *info, const void *data, size_t size)
{
    (void)data; (void)size;
    g_bytes_unref((GBytes *)info);
}

static CGImageRef imageForBuffer(WPEBuffer *buffer)
{
    WPEBufferSHM *shm = WPE_BUFFER_SHM(buffer);
    GBytes *bytes = wpe_buffer_shm_get_data(shm);
    gsize size = 0;
    const void *data = g_bytes_get_data(bytes, &size);
    CGDataProviderRef provider = CGDataProviderCreateWithData(g_bytes_ref(bytes), data, size, releaseBytes);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    /* WebKit's Skia renders native 0xAARRGGBB words on big-endian PowerPC (measured). */
    CGImageRef image = CGImageCreate(wpe_buffer_get_width(buffer), wpe_buffer_get_height(buffer), 8, 32,
                                     wpe_buffer_shm_get_stride(shm), space,
                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

static gboolean frameCallback(gpointer data)
{
    WPEViewCocoa *self = WPE_VIEW_COCOA(data);
    WPEView *view = WPE_VIEW(self);
    WPEBuffer *previous = self->committedBuffer;
    self->committedBuffer = self->pendingBuffer;
    self->pendingBuffer = NULL;
    if (self->committedBuffer && WPE_IS_BUFFER_SHM(self->committedBuffer) && getenv("FROSTBYTE_DEBUG_FRAMES")) {
        /* sample a few words of the frame: top-left, centre, and the first block row */
        WPEBufferSHM *shm = WPE_BUFFER_SHM(self->committedBuffer);
        gsize size = 0;
        const guint32 *px = g_bytes_get_data(wpe_buffer_shm_get_data(shm), &size);
        guint stride = wpe_buffer_shm_get_stride(shm) / 4;
        int w = wpe_buffer_get_width(self->committedBuffer), h = wpe_buffer_get_height(self->committedBuffer);
        static int frames;
        if (frames++ < 20 && px && h > 50 && w > 700)
            fprintf(stderr, "frostbyte-frame %d: %dx%d stride %u  [0,0]=%08x [40,60]=%08x [40,180]=%08x [40,300]=%08x [h/2,w/2]=%08x\n",
                    frames, w, h, stride * 4, px[0], px[40 * stride + 60], px[40 * stride + 180], px[40 * stride + 300],
                    px[(h / 2) * stride + w / 2]);
    }
    if (self->committedBuffer) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        if (WPE_IS_BUFFER_DMA_BUF(self->committedBuffer)) {
            if (![self->nsview presentDMABuf:WPE_BUFFER_DMA_BUF(self->committedBuffer)])
                fprintf(stderr, "frostbyte: could not present a shared GPU buffer\n");
        } else {
            [self->nsview leaveGL];
            [self->nsview setFrameImage:imageForBuffer(self->committedBuffer)];
            [self->nsview display];        /* draw now, while the buffer is ours */
        }
        [pool release];
    }
    if (previous) {
        wpe_view_buffer_released(view, previous);
        g_object_unref(previous);
    }
    if (self->committedBuffer)
        wpe_view_buffer_rendered(view, self->committedBuffer);
    return G_SOURCE_CONTINUE;
}

/* Draw the frame on screen again (a re-attached GL surface starts empty). */
static void presentCommittedAgain(WPEView *view)
{
    WPEViewCocoa *self = WPE_VIEW_COCOA(view);
    if (self->committedBuffer && WPE_IS_BUFFER_DMA_BUF(self->committedBuffer))
        [self->nsview presentDMABuf:WPE_BUFFER_DMA_BUF(self->committedBuffer)];
}

static gboolean frameDispatch(GSource *source, GSourceFunc callback, gpointer userData)
{
    if (g_source_get_ready_time(source) == -1)
        return G_SOURCE_CONTINUE;
    g_source_set_ready_time(source, -1);
    return callback(userData);
}

static GSourceFuncs frameSourceFuncs = { NULL, NULL, frameDispatch, NULL, NULL, NULL };

/* CSS cursor names WebKit sends -> what Mac OS X 10.5 has (not-allowed, contextual-menu, copy, alias are 10.6+). */
static NSCursor *cursorForName(const char *name)
{
    if (!name) return [NSCursor arrowCursor];
    if (!strcmp(name, "pointer")) return [NSCursor pointingHandCursor];
    if (!strcmp(name, "text") || !strcmp(name, "vertical-text")) return [NSCursor IBeamCursor];
    if (!strcmp(name, "crosshair") || !strcmp(name, "cell")) return [NSCursor crosshairCursor];
    if (!strcmp(name, "grab") || !strcmp(name, "move") || !strcmp(name, "all-scroll")) return [NSCursor openHandCursor];
    if (!strcmp(name, "grabbing")) return [NSCursor closedHandCursor];
    if (!strcmp(name, "ew-resize") || !strcmp(name, "e-resize") || !strcmp(name, "w-resize") || !strcmp(name, "col-resize"))
        return [NSCursor resizeLeftRightCursor];
    if (!strcmp(name, "ns-resize") || !strcmp(name, "n-resize") || !strcmp(name, "s-resize") || !strcmp(name, "row-resize"))
        return [NSCursor resizeUpDownCursor];
    return [NSCursor arrowCursor];
}

static void wpe_view_cocoa_set_cursor_from_name(WPEView *view, const char *name)
{
    FB_POOL_BEGIN;
    [WPE_VIEW_COCOA(view)->nsview setPageCursor:cursorForName(name)];
    FB_POOL_END;
}

static gboolean wpe_view_cocoa_render_buffer(WPEView *view, WPEBuffer *buffer, const WPERectangle *damage,
                                             guint nDamage, GError **error)
{
    (void)damage; (void)nDamage;
    WPEViewCocoa *self = WPE_VIEW_COCOA(view);
    if (WPE_IS_BUFFER_DMA_BUF(buffer)) {
        if (wpe_buffer_dma_buf_get_format(WPE_BUFFER_DMA_BUF(buffer)) != 0x34325241u /* 'AR24', native ARGB */) {
            g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "unsupported shared buffer format");
            return FALSE;
        }
    } else if (!WPE_IS_BUFFER_SHM(buffer)) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED,
                            "FrostByte's Cocoa backend shows shared-memory or LeopardGPU buffers only");
        return FALSE;
    } else if (wpe_buffer_shm_get_format(WPE_BUFFER_SHM(buffer)) != WPE_PIXEL_FORMAT_ARGB8888) {
        g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "unsupported SHM pixel format");
        return FALSE;
    }
    if (self->pendingBuffer)
        g_object_unref(self->pendingBuffer);  /* superseded before it was shown */
    self->pendingBuffer = g_object_ref(buffer);

    /* Present at most once per 1/60 s, like the headless backend. */
    gint64 now = g_get_monotonic_time();
    gint64 next = self->lastFrameTime ? self->lastFrameTime + G_USEC_PER_SEC / 60 : now;
    self->lastFrameTime = now;
    g_source_set_ready_time(self->frameSource, next <= now ? 0 : next);
    return TRUE;
}

static void viewToplevelChanged(WPEView *view, GParamSpec *pspec, gpointer data)
{
    FB_POOL_BEGIN;
    (void)pspec; (void)data;
    WPEViewCocoa *self = WPE_VIEW_COCOA(view);
    WPEToplevel *toplevel = wpe_view_get_toplevel(view);
    if (!toplevel || !WPE_IS_TOPLEVEL_COCOA(toplevel)) {
        [self->nsview removeFromSuperview];
        wpe_view_unmap(view);
        FB_POOL_END;
        return;
    }
    NSWindow *window = WPE_TOPLEVEL_COCOA(toplevel)->window;
    NSView *host = WPE_TOPLEVEL_COCOA(toplevel)->viewHost;
    if (host) {
        /* A browser window with tabs: every view fills the host; only the visible one shows. */
        if ([self->nsview superview] != host) {
            [self->nsview removeFromSuperview];
            [self->nsview setFrame:[host bounds]];
            [host addSubview:self->nsview];
        }
    } else if ([self->nsview window] != window)
        [window setContentView:self->nsview];
    [self->nsview setHidden:!wpe_view_get_visible(view)];
    if (wpe_view_get_visible(view))
        [window makeFirstResponder:self->nsview];
    NSSize s = [self->nsview bounds].size;
    wpe_view_resized(view, (int)s.width, (int)s.height);
    wpe_view_map(view);
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if ([window isKeyWindow])
        wpe_toplevel_state_changed(toplevel, (WPEToplevelState)(wpe_toplevel_get_state(toplevel) | WPE_TOPLEVEL_STATE_ACTIVE));
    if ([window isKeyWindow] && [window firstResponder] == self->nsview)
        wpe_view_focus_in(view);
    FB_POOL_END;
}

/* Hidden views (background tabs) are unmapped by WPE, which stops their rendering. */
static void viewVisibleChanged(WPEView *view, GParamSpec *pspec, gpointer data)
{
    FB_POOL_BEGIN;
    (void)pspec; (void)data;
    WPEViewCocoa *self = WPE_VIEW_COCOA(view);
    BOOL visible = wpe_view_get_visible(view);
    NSWindow *window = [self->nsview window];
    if (!visible && window && [window firstResponder] == self->nsview)
        [window makeFirstResponder:nil];
    [self->nsview setHidden:!visible];
    FB_POOL_END;
}

static void wpe_view_cocoa_constructed(GObject *object)
{
    FB_POOL_BEGIN;
    G_OBJECT_CLASS(wpe_view_cocoa_parent_class)->constructed(object);
    WPEViewCocoa *self = WPE_VIEW_COCOA(object);
    self->nsview = [[FBWPEView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 700)];
    self->nsview->wpeView = WPE_VIEW(self);
    [self->nsview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    g_signal_connect(object, "notify::toplevel", G_CALLBACK(viewToplevelChanged), NULL);
    g_signal_connect(object, "notify::visible", G_CALLBACK(viewVisibleChanged), NULL);

    self->frameSource = g_source_new(&frameSourceFuncs, sizeof(GSource));
    g_source_set_name(self->frameSource, "FrostByte Cocoa frame");
    g_source_set_callback(self->frameSource, frameCallback, self, NULL);
    g_source_set_ready_time(self->frameSource, -1);
    g_source_attach(self->frameSource, g_main_context_get_thread_default());
    FB_POOL_END;
}

static void wpe_view_cocoa_dispose(GObject *object)
{
    FB_POOL_BEGIN;
    WPEViewCocoa *self = WPE_VIEW_COCOA(object);
    if (self->frameSource) {
        g_source_destroy(self->frameSource);
        g_source_unref(self->frameSource);
        self->frameSource = NULL;
    }
    g_clear_object(&self->pendingBuffer);
    g_clear_object(&self->committedBuffer);
    if (self->nsview) {
        self->nsview->wpeView = NULL;
        [self->nsview removeFromSuperview];
        [self->nsview release];
        self->nsview = nil;
    }
    G_OBJECT_CLASS(wpe_view_cocoa_parent_class)->dispose(object);
    FB_POOL_END;
}

static void wpe_view_cocoa_class_init(WPEViewCocoaClass *klass)
{
    GObjectClass *objectClass = G_OBJECT_CLASS(klass);
    objectClass->constructed = wpe_view_cocoa_constructed;
    objectClass->dispose = wpe_view_cocoa_dispose;
    WPE_VIEW_CLASS(klass)->render_buffer = wpe_view_cocoa_render_buffer;
    WPE_VIEW_CLASS(klass)->set_cursor_from_name = wpe_view_cocoa_set_cursor_from_name;
}

static void wpe_view_cocoa_init(WPEViewCocoa *self) { (void)self; }

void *wpe_view_cocoa_get_nsview(WPEViewCocoa *view)
{
    g_return_val_if_fail(WPE_IS_VIEW_COCOA(view), NULL);
    return view->nsview;
}

/* ------------------------------------------------------------------------------------------ */
/* WPEKeymapCocoa: events already carry keysyms; report the current modifier state only. */

struct _WPEKeymapCocoa { WPEKeymap parent; };
G_DEFINE_FINAL_TYPE(WPEKeymapCocoa, wpe_keymap_cocoa, WPE_TYPE_KEYMAP)

static gboolean keymapNoEntries(WPEKeymap *k, guint keyval, WPEKeymapEntry **entries, guint *n)
{
    (void)k; (void)keyval;
    *entries = NULL;
    *n = 0;
    return FALSE;
}

static gboolean keymapNoTranslate(WPEKeymap *k, guint keycode, WPEModifiers m, int group, guint *keyval,
                                  int *effectiveGroup, int *level, WPEModifiers *consumed)
{
    (void)k; (void)keycode; (void)m; (void)group;
    if (keyval) *keyval = 0;
    if (effectiveGroup) *effectiveGroup = 0;
    if (level) *level = 0;
    if (consumed) *consumed = 0;
    return FALSE;
}

static WPEModifiers keymapModifiers(WPEKeymap *k)
{
    (void)k;
    return keyboardModifiers([[NSApp currentEvent] modifierFlags]);
}

static void wpe_keymap_cocoa_class_init(WPEKeymapCocoaClass *klass)
{
    WPEKeymapClass *keymapClass = WPE_KEYMAP_CLASS(klass);
    keymapClass->get_entries_for_keyval = keymapNoEntries;
    keymapClass->translate_keyboard_state = keymapNoTranslate;
    keymapClass->get_modifiers = keymapModifiers;
}

static void wpe_keymap_cocoa_init(WPEKeymapCocoa *self) { (void)self; }

/* ------------------------------------------------------------------------------------------ */
/* WPEClipboardCocoa: WPE's clipboard backed by the general NSPasteboard.
 * WebKit's copies arrive through ->changed (is_local) and are written to the pasteboard; when
 * another application has copied something (the pasteboard's changeCount moved, checked whenever
 * FrostByte becomes active) WPE is told the clipboard changed remotely and reads it through ->read. */

#define WPE_TYPE_CLIPBOARD_COCOA (wpe_clipboard_cocoa_get_type())
G_DECLARE_FINAL_TYPE(WPEClipboardCocoa, wpe_clipboard_cocoa, WPE, CLIPBOARD_COCOA, WPEClipboard)

struct _WPEClipboardCocoa {
    WPEClipboard parent;
    NSInteger knownChangeCount;     /* the pasteboard as we last wrote or announced it */
    id observer;
    guint timer;                    /* 1 Hz check for copies made while we stay active (pbcopy) */
};

G_DEFINE_FINAL_TYPE(WPEClipboardCocoa, wpe_clipboard_cocoa, WPE_TYPE_CLIPBOARD)

static void clipboardCocoaChanged(WPEClipboard *clipboard, GPtrArray *formats, gboolean isLocal, WPEClipboardContent *content)
{
    WPEClipboardCocoa *self = WPE_CLIPBOARD_COCOA(clipboard);
    WPE_CLIPBOARD_CLASS(wpe_clipboard_cocoa_parent_class)->changed(clipboard, formats, isLocal, content);
    if (!isLocal)
        return;
    FB_POOL_BEGIN;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    const char *text = content ? wpe_clipboard_content_get_text(content) : NULL;
    GBytes *html = content ? wpe_clipboard_content_get_bytes(content, "text/html") : NULL;   /* transfer none */
    NSMutableArray *types = [NSMutableArray array];
    if (text)
        [types addObject:NSStringPboardType];
    if (html)
        [types addObject:NSHTMLPboardType];
    [pb declareTypes:types owner:nil];
    if (text)
        [pb setString:[NSString stringWithUTF8String:text] forType:NSStringPboardType];
    if (html) {
        gsize size = 0;
        const char *data = g_bytes_get_data(html, &size);
        NSString *s = [[[NSString alloc] initWithBytes:data length:size encoding:NSUTF8StringEncoding] autorelease];
        if (s)
            [pb setString:s forType:NSHTMLPboardType];
    }
    self->knownChangeCount = [pb changeCount];
    FB_POOL_END;
}

static GBytes *clipboardCocoaRead(WPEClipboard *clipboard, const char *format)
{
    (void)clipboard;
    GBytes *bytes = NULL;
    FB_POOL_BEGIN;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *s = nil;
    if (!strcmp(format, "text/plain") || !strcmp(format, "text/plain;charset=utf-8"))
        s = [pb stringForType:NSStringPboardType];
    else if (!strcmp(format, "text/html"))
        s = [pb stringForType:NSHTMLPboardType];
    if (s) {
        const char *utf8 = [s UTF8String];
        bytes = g_bytes_new(utf8, strlen(utf8));
    }
    FB_POOL_END;
    return bytes;
}

/* Someone else may have copied while we were in the background: tell WPE what is there now. */
static void clipboardCocoaSync(WPEClipboardCocoa *self)
{
    FB_POOL_BEGIN;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSInteger count = [pb changeCount];
    if (count != self->knownChangeCount) {
        self->knownChangeCount = count;
        NSArray *types = [pb types];
        GPtrArray *formats = g_ptr_array_new();
        if ([types containsObject:NSStringPboardType]) {
            g_ptr_array_add(formats, (gpointer)g_intern_static_string("text/plain"));
            g_ptr_array_add(formats, (gpointer)g_intern_static_string("text/plain;charset=utf-8"));
        }
        if ([types containsObject:NSHTMLPboardType])
            g_ptr_array_add(formats, (gpointer)g_intern_static_string("text/html"));
        g_ptr_array_add(formats, NULL);
        WPE_CLIPBOARD_CLASS(wpe_clipboard_cocoa_parent_class)->changed(WPE_CLIPBOARD(self), formats, FALSE, NULL);
        g_ptr_array_unref(formats);
    }
    FB_POOL_END;
}

static gboolean clipboardCocoaTick(gpointer data)
{
    clipboardCocoaSync(WPE_CLIPBOARD_COCOA(data));
    return G_SOURCE_CONTINUE;
}

@interface FBClipboardObserver : NSObject {
@public
    WPEClipboardCocoa *clipboard;   /* not retained: the clipboard owns us */
}
@end

@implementation FBClipboardObserver
- (void)applicationDidBecomeActive:(NSNotification *)n { (void)n; clipboardCocoaSync(clipboard); }
@end

static void wpe_clipboard_cocoa_constructed(GObject *object)
{
    G_OBJECT_CLASS(wpe_clipboard_cocoa_parent_class)->constructed(object);
    WPEClipboardCocoa *self = WPE_CLIPBOARD_COCOA(object);
    FB_POOL_BEGIN;
    self->knownChangeCount = -1;
    clipboardCocoaSync(self);
    FBClipboardObserver *observer = [[FBClipboardObserver alloc] init];
    observer->clipboard = self;
    [[NSNotificationCenter defaultCenter] addObserver:observer selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification object:nil];
    self->observer = observer;
    self->timer = g_timeout_add(1000, clipboardCocoaTick, self);
    FB_POOL_END;
}

static void wpe_clipboard_cocoa_dispose(GObject *object)
{
    WPEClipboardCocoa *self = WPE_CLIPBOARD_COCOA(object);
    if (self->timer) {
        g_source_remove(self->timer);
        self->timer = 0;
    }
    if (self->observer) {
        FB_POOL_BEGIN;
        [[NSNotificationCenter defaultCenter] removeObserver:self->observer];
        [self->observer release];
        self->observer = nil;
        FB_POOL_END;
    }
    G_OBJECT_CLASS(wpe_clipboard_cocoa_parent_class)->dispose(object);
}

static void wpe_clipboard_cocoa_class_init(WPEClipboardCocoaClass *klass)
{
    G_OBJECT_CLASS(klass)->constructed = wpe_clipboard_cocoa_constructed;
    G_OBJECT_CLASS(klass)->dispose = wpe_clipboard_cocoa_dispose;
    WPE_CLIPBOARD_CLASS(klass)->changed = clipboardCocoaChanged;
    WPE_CLIPBOARD_CLASS(klass)->read = clipboardCocoaRead;
}

static void wpe_clipboard_cocoa_init(WPEClipboardCocoa *self) { (void)self; }

/* ------------------------------------------------------------------------------------------ */
/* WPEDisplayCocoa */

struct _WPEDisplayCocoa { WPEDisplay parent; };
G_DEFINE_FINAL_TYPE(WPEDisplayCocoa, wpe_display_cocoa, WPE_TYPE_DISPLAY)

static gboolean wpe_display_cocoa_connect(WPEDisplay *display, GError **error)
{
    (void)error;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    /* An unbundled executable starts as a background process: make it a real app with a
     * Dock icon and key windows (TransformProcessType, 10.3+). */
    ProcessSerialNumber psn = { 0, kCurrentProcess };
    TransformProcessType(&psn, kProcessTransformToForegroundApplication);
    [NSApp finishLaunching];
    /* CSS system-ui resolves to WPE's font-name setting ("Sans 10" by default, which fontconfig
     * turns into sans-serif). Report the Mac UI font instead (Lucida Grande on 10.5); WebKit keeps
     * the family and drops the size. */
    NSString *family = [[NSFont systemFontOfSize:0] familyName];
    if ([family length]) {
        char *fontName = g_strdup_printf("%s %d", [family UTF8String], (int)[NSFont systemFontSize]);
        wpe_settings_set_string(wpe_display_get_settings(display), WPE_SETTING_FONT_NAME, fontName,
                                WPE_SETTINGS_SOURCE_PLATFORM, NULL);
        g_free(fontName);
    }
    if (!s_pumpSource)
        s_pumpSource = g_timeout_add(8, cocoaPump, NULL);
    [pool release];
    return TRUE;
}

static WPEView *wpe_display_cocoa_create_view(WPEDisplay *display)
{
    return WPE_VIEW(g_object_new(WPE_TYPE_VIEW_COCOA, "display", display, NULL));
}

static WPEToplevel *wpe_display_cocoa_create_toplevel(WPEDisplay *display, guint maxViews)
{
    (void)maxViews;
    return WPE_TOPLEVEL(g_object_new(WPE_TYPE_TOPLEVEL_COCOA, "display", display, NULL));
}

/* in wpe-cocoa-egl.c: epoxy and Cocoa's OpenGL headers cannot share a translation unit */
gpointer frostbyte_cocoa_get_egl_display(WPEDisplay *display, GError **error);

static WPEKeymap *wpe_display_cocoa_get_keymap(WPEDisplay *display)
{
    (void)display;
    return WPE_KEYMAP(g_object_new(WPE_TYPE_KEYMAP_COCOA, NULL));
}

static WPEClipboard *wpe_display_cocoa_get_clipboard(WPEDisplay *display)
{
    return WPE_CLIPBOARD(g_object_new(WPE_TYPE_CLIPBOARD_COCOA, "display", display, NULL));
}

static void wpe_display_cocoa_class_init(WPEDisplayCocoaClass *klass)
{
    WPEDisplayClass *displayClass = WPE_DISPLAY_CLASS(klass);
    displayClass->connect = wpe_display_cocoa_connect;
    displayClass->create_view = wpe_display_cocoa_create_view;
    displayClass->create_toplevel = wpe_display_cocoa_create_toplevel;
    displayClass->get_egl_display = frostbyte_cocoa_get_egl_display;
    displayClass->get_keymap = wpe_display_cocoa_get_keymap;
    displayClass->get_clipboard = wpe_display_cocoa_get_clipboard;
}

static void wpe_display_cocoa_init(WPEDisplayCocoa *self) { (void)self; }

WPEDisplay *wpe_display_cocoa_new(void)
{
    return WPE_DISPLAY(g_object_new(WPE_TYPE_DISPLAY_COCOA, NULL));
}
